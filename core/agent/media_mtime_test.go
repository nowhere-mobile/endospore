package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hanwen/go-fuse/v2/fuse"
)

// NWP-20260828-18: deferredFile.MTime carries TWO encodings. The seal stamps UnixNano
// (info.ModTime().UnixNano()); the web importer writes UNIX SECONDS into the same json field ("t"),
// documented as such at cmd/importwasm/write.go's mediaFile.MTime. Everything that reads the field assumed
// nanos, so a web-imported deferred file's mtime came back as 1 Jan 1970.
func TestDeferredMTimeNanosNormalizesBothEncodings(t *testing.T) {
	ref := time.Date(2026, 3, 4, 5, 6, 7, 0, time.UTC)
	for _, c := range []struct {
		why  string
		in   int64
		want int64
	}{
		{"seal-written UnixNano passes through untouched", ref.UnixNano(), ref.UnixNano()},
		{"importer-written unix SECONDS scale up to nanos", ref.Unix(), ref.UnixNano()},
		{"0 means unknown and stays 0", 0, 0},
		{"a negative (pre-epoch/corrupt) value is treated as unknown", -5, 0},
		{"just under the ceiling is seconds", mtimeSecondsCeiling - 1, (mtimeSecondsCeiling - 1) * int64(time.Second)},
		{"the ceiling itself is already nanos", mtimeSecondsCeiling, mtimeSecondsCeiling},
	} {
		if got := deferredMTimeNanos(c.in); got != c.want {
			t.Errorf("deferredMTimeNanos(%d) = %d, want %d (%s)", c.in, got, c.want, c.why)
		}
	}

	// The scale must never overflow into a negative/garbage date. int64 tops out at ~9.22e18, so the
	// seconds branch is only safe below ~9.22e9 -- the ceiling has to stay under that, and every value at
	// or above it must be returned unscaled.
	for _, in := range []int64{
		mtimeSecondsCeiling - 1, mtimeSecondsCeiling, 1 << 40, 1 << 62, 1<<63 - 1,
	} {
		if got := deferredMTimeNanos(in); got < 0 {
			t.Errorf("deferredMTimeNanos(%d) = %d: overflowed to a negative time", in, got)
		}
	}
}

// The stub's getattr is where the unit bug was USER-VISIBLE: a web-imported photo showed a 1970 date in Files
// and Gallery, and per NWP-20260828-17 a 1-8 MiB file is never materialized, so nothing ever corrected it.
func TestSetFileAttrRendersImporterSecondsAsARealDate(t *testing.T) {
	want := time.Date(2024, 5, 6, 7, 8, 9, 0, time.UTC)

	var imported fuse.Attr
	setFileAttr(&imported, deferredFile{Mode: 0o644, Size: 10, MTime: want.Unix()}, 0, 0)
	if int64(imported.Mtime) != want.Unix() {
		t.Errorf("importer-written SECONDS: st_mtime = %d (%v), want %d (%v)",
			imported.Mtime, time.Unix(int64(imported.Mtime), 0).UTC(), want.Unix(), want)
	}

	// and the seal-written nanos path must be unchanged by the normalization
	var sealed fuse.Attr
	setFileAttr(&sealed, deferredFile{Mode: 0o644, Size: 10, MTime: want.UnixNano()}, 0, 0)
	if int64(sealed.Mtime) != want.Unix() {
		t.Errorf("seal-written NANOS regressed: st_mtime = %d, want %d", sealed.Mtime, want.Unix())
	}
}

// The core of NWP-20260828-15: materialize used copyFile alone, which stamps the FETCH time. That misses the
// next seal's byte-carry fast path (prev.MTime == mt), so identical bytes are re-read, re-chunked and
// re-UPLOADED every login -- and for a file that lands essential it perturbs the shared tar's ustar header
// and defeats dedup across the surrounding CDC chunk.
func TestMaterializeRestoresRecordedMTime(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-mtime-nanos")

	const rel = "app.maps/files/maps/one.mwm"
	want := time.Date(2019, 3, 4, 5, 6, 7, 0, time.UTC)
	df, ok := m1.Deferred[rel]
	if !ok {
		t.Fatalf("harness must leave %s deferred; deferred=%v", rel, keysOf(m1.Deferred))
	}
	df.MTime = want.UnixNano() // as the SEAL records it
	m1.Deferred[rel] = df

	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)

	fi, err := os.Stat(filepath.Join(under, "one.mwm"))
	if err != nil {
		t.Fatalf("materialized file must exist in .under: %v", err)
	}
	if got := fi.ModTime().UTC(); !got.Equal(want) {
		t.Fatalf("materialize must restore the RECORDED mtime, not the fetch time: got %v, want %v", got, want)
	}
}

// Same path, but for a profile that came from the WEB IMPORTER, whose record is in seconds. Without the
// normalization this writes 1 Jan 1970 onto the user's photo -- strictly worse than leaving the fetch time,
// which is why the two halves of this fix have to land together.
func TestMaterializeRestoresImporterSecondsMTime(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-mtime-secs")

	const rel = "app.maps/files/maps/one.mwm"
	want := time.Date(2021, 7, 8, 9, 10, 11, 0, time.UTC)
	df, ok := m1.Deferred[rel]
	if !ok {
		t.Fatalf("harness must leave %s deferred; deferred=%v", rel, keysOf(m1.Deferred))
	}
	df.MTime = want.Unix() // as the WEB IMPORTER records it
	m1.Deferred[rel] = df

	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)

	fi, err := os.Stat(filepath.Join(under, "one.mwm"))
	if err != nil {
		t.Fatalf("materialized file must exist in .under: %v", err)
	}
	if got := fi.ModTime().UTC(); !got.Equal(want) {
		t.Fatalf("importer-written SECONDS must materialize to the real date, not 1970 or the fetch time: got %v, want %v", got, want)
	}
}

// The payoff, stated as the seal sees it: after a materialize the next walk must find the file with the SAME
// mtime the manifest recorded, which is the condition the byte-carry fast path keys on
// (prev.Size == sz && prev.MTime == mt). This is what stops the per-login re-upload.
func TestMaterializedFileMatchesTheByteCarryCondition(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	base, _, _, dk, srcB, _, under, m1 := overlayRaceSetup(t, "od-mtime-carry")

	const rel = "app.maps/files/maps/one.mwm"
	df, ok := m1.Deferred[rel]
	if !ok {
		t.Fatalf("harness must leave %s deferred; deferred=%v", rel, keysOf(m1.Deferred))
	}
	recorded := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	df.MTime = recorded.UnixNano()
	m1.Deferred[rel] = df

	srv := newMediaServer(base, dk, m1, filepath.Join(srcB, mediaCacheDirName))
	srv.materializePins(map[string]bool{"app.maps": true}, 0, map[string]string{"app.maps/files/maps": under}, nil)

	fi, err := os.Stat(filepath.Join(under, "one.mwm"))
	if err != nil {
		t.Fatalf("materialized file must exist in .under: %v", err)
	}
	// exactly the comparison walkChunks makes
	if fi.Size() != df.Size || fi.ModTime().UnixNano() != df.MTime {
		t.Fatalf("byte-carry would MISS -> re-read + re-upload every login: on-disk (%d, %d) != recorded (%d, %d)",
			fi.Size(), fi.ModTime().UnixNano(), df.Size, df.MTime)
	}
}
