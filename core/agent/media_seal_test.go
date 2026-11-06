package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// DIA-20260813-06 (#135): parseMediaOverlayUnders must RESOLVE each overlay's .under bind from the mount
// table, not compute it from one assumed layout. The computed path is only right for the CE scope (src ==
// the user dir); the EXTERNAL scope's binds live in the chooser's files dir under /data/user/<uid>, so for
// src=/data/media/<uid> the computed path never exists and the walker skipped the whole overlaid subtree.
// Live on 2026-08-13 (odtest11): ~58MB of fetched-local ContentDownload vanished from every #media walk,
// the shrink guard refused the collapsed manifest, and the session could not log off. The fixture lines
// below are the REAL /proc/mounts shapes from that device (options trimmed), with each .under leaf respelled
// in the injective underLeaf form NWP-20261011-74 introduced (TestUnderLeafPinsTheSealFixtures pins them).
func TestParseMediaOverlayUndersResolvesFromMountTable(t *testing.T) {
	fixture := strings.Join([]string{
		// mirror alias FIRST -- pins that the canonical /data path is preferred regardless of table order
		"/dev/block/dm-12 /data_mirror/data_ce/null/11/com.nowhere.chooser/files/.nowhere-media-ext/.under/Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload f2fs rw 0 0",
		"nowhere_media /data/media/11/Android/data/net.peakgames.toonblast/files/ContentDownload fuse.nowheremedia rw,allow_other 0 0",
		"/dev/block/dm-12 /data/user/11/com.nowhere.chooser/files/.nowhere-media-ext/.under/Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload f2fs rw 0 0",
		// a DIFFERENT user's bind with the same leaf -- must not satisfy uid 11's overlay
		"/dev/block/dm-12 /data/user/10/com.nowhere.chooser/files/.nowhere-media-ext/.under/Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload f2fs rw 0 0",
		// CE-scope pair (src=/data/user/11): overlay + its bind, both under the user dir
		"nowhere_media /data/user/11/com.nowhere.chooser/files/.appcode/com.google.android.gms fuse.nowheremedia rw,allow_other 0 0",
		"/dev/block/dm-12 /data/user/11/com.nowhere.chooser/files/.nowhere-media/.under/com.nowhere.chooser_sfiles_s.appcode_scom.google.android.gms f2fs rw 0 0",
		// an ext overlay whose bind is GONE (reconcile/sweep race) -- must fall back to the computed
		// (nonexistent) path so the walker SKIPS it rather than walking through the overlay
		"nowhere_media /data/media/11/Android/data/com.example.orphan/files/Big fuse.nowheremedia rw,allow_other 0 0",
	}, "\n")

	// EXTERNAL scope: the 2026-08-13 failure case. The overlay must map to the chooser-files bind.
	got := parseMediaOverlayUnders(strings.NewReader(fixture), "/data/media/11")
	extOverlay := "/data/media/11/Android/data/net.peakgames.toonblast/files/ContentDownload"
	wantExt := "/data/user/11/com.nowhere.chooser/files/.nowhere-media-ext/.under/Android_sdata_snet.peakgames.toonblast_sfiles_sContentDownload"
	if got[extOverlay] != wantExt {
		t.Errorf("ext overlay mapped to %q, want the live chooser-files bind %q", got[extOverlay], wantExt)
	}
	// Orphaned overlay: no live bind -> the computed nonexistent path (walker skips; deferred entries carried).
	orphan := "/data/media/11/Android/data/com.example.orphan/files/Big"
	wantOrphan := "/data/media/11/" + mediaCacheRel + "/.under/Android_sdata_scom.example.orphan_sfiles_sBig"
	if got[orphan] != wantOrphan {
		t.Errorf("orphaned overlay mapped to %q, want the computed skip path %q", got[orphan], wantOrphan)
	}

	// CE scope: resolution must agree with the (already-correct) computed layout -- no regression.
	got = parseMediaOverlayUnders(strings.NewReader(fixture), "/data/user/11")
	ceOverlay := "/data/user/11/com.nowhere.chooser/files/.appcode/com.google.android.gms"
	wantCE := "/data/user/11/com.nowhere.chooser/files/.nowhere-media/.under/com.nowhere.chooser_sfiles_s.appcode_scom.google.android.gms"
	if got[ceOverlay] != wantCE {
		t.Errorf("CE overlay mapped to %q, want %q", got[ceOverlay], wantCE)
	}
}

// The pre-fix behaviour, kept from regressing the other way: a table with overlays but NO binds at all must
// still return a map (never nil) whose values are skip paths -- an empty return would send the walker THROUGH
// the overlays (fetch storms on a live daemon, errors/hangs on a dead one).
func TestParseMediaOverlayUndersNoBindsStillSkips(t *testing.T) {
	fixture := "nowhere_media /data/media/11/Android/data/net.peakgames.toonblast/files/ContentDownload fuse.nowheremedia rw 0 0\n"
	got := parseMediaOverlayUnders(strings.NewReader(fixture), "/data/media/11")
	if len(got) != 1 {
		t.Fatalf("want 1 mapped overlay, got %d", len(got))
	}
	for mp, under := range got {
		if !strings.HasPrefix(under, "/data/media/11/"+mediaCacheRel+"/.under/") {
			t.Errorf("overlay %q mapped to %q, want a computed skip path", mp, under)
		}
	}
}

// DIA-20260813-07 (#135): the DOUBLE-COUNT invariant -- a rel's bytes must never live in the essential tar
// AND in Deferred within one manifest. odtest11's head reached exactly that state on 2026-08-13 (83 essential
// chunks alongside deferred entries apparently covering the same content) and wedged every logoff behind the
// shrink guard until a forced seal repaired it. The formation path is still unproven; these tests pin the two
// halves of the invariant on the exact shape that session had -- previously-deferred files MATERIALISED
// locally (mediad fetch / the user played the game) with the overlays down at seal time (post-sweep).
func TestSealMaterialisedDeferredNeverDoubleCounted(t *testing.T) {
	preGateSeal(t) // NWP-20260923-02: a vault head an older handset wrote; serving it is unchanged
	setup := func(t *testing.T, tag string) (base, name, pass string, srcB string, m1 chunkManifest) {
		t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
		t.Setenv("NOWHERE_MEDIA_MIN", "4096")
		t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
		base = newHTTPStore(t)
		name, pass = tag, "race horse battery staple"
		createVault(base, name, pass)
		srcA := t.TempDir()
		if err := os.MkdirAll(filepath.Join(srcA, "app.maps/files/maps"), 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/index.json"), []byte("REAL-INDEX"), 0o644)
		os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/one.mwm"), prBytes(6<<20), 0o644)
		os.WriteFile(filepath.Join(srcA, "app.maps/files/maps/two.mwm"), append(prBytes(5<<20), 0xEE), 0o644)
		pushProfile(base, name, pass, srcA)
		dk := resolveDK(base, name, pass, nil)
		m1 = headManifest(t, base, dk, name, pass)
		if len(m1.Deferred) != 2 {
			t.Fatalf("setup: want 2 deferred, got %d", len(m1.Deferred))
		}
		_, srcB = restoreManifest(t, base, name, pass)
		// The restore leaves deferred files unmaterialised; "materialise" them as mediad's fetch (or the
		// app's own re-download) would -- same rels, real bytes, overlays down.
		os.WriteFile(filepath.Join(srcB, "app.maps/files/maps/one.mwm"), prBytes(6<<20), 0o644)
		os.WriteFile(filepath.Join(srcB, "app.maps/files/maps/two.mwm"), append(prBytes(5<<20), 0xEE), 0o644)
		return
	}
	sums := func(m chunkManifest) (essB, defB int64) {
		for _, z := range m.Sizes {
			essB += z
		}
		for _, d := range m.Deferred {
			defB += d.Size
		}
		return
	}

	// Half 1: the walk still classifies the files DEFERRED (threshold below their size). The fresh
	// classification must SUPERSEDE the carried entries -- present once in Deferred, absent from essential.
	t.Run("rematerialised-stays-deferred", func(t *testing.T) {
		base, name, pass, srcB, _ := setup(t, "oddup1")
		pushProfile(base, name, pass, srcB)
		dk := resolveDK(base, name, pass, nil)
		m2 := headManifest(t, base, dk, name, pass)
		if len(m2.Deferred) != 2 {
			t.Fatalf("want the 2 files deferred once, got %d entries", len(m2.Deferred))
		}
		essB, defB := sums(m2)
		if essB > 1<<20 {
			t.Errorf("essential holds %dB -- deferred bytes leaked into the tar (double count)", essB)
		}
		if defB > 13<<20 {
			t.Errorf("deferred holds %dB for ~11MB of content -- entries duplicated", defB)
		}
	})

	// Half 2 (the odtest11 head's shape): the files classify ESSENTIAL this seal (threshold raised above
	// their size -- the app-essential path). The carried deferred entries must be DROPPED via the walker's
	// seen-set: bytes in the tar exactly once, Deferred empty.
	t.Run("rematerialised-goes-essential", func(t *testing.T) {
		base, name, pass, srcB, _ := setup(t, "oddup2")
		t.Setenv("NOWHERE_MEDIA_MIN", "67108864") // 64MB: both files now walk essential
		pushProfile(base, name, pass, srcB)
		dk := resolveDK(base, name, pass, nil)
		m2 := headManifest(t, base, dk, name, pass)
		if len(m2.Deferred) != 0 {
			t.Errorf("carried deferred entries survived files the walk sealed essential: %d entries -- THE double-count", len(m2.Deferred))
		}
		essB, defB := sums(m2)
		if essB < 11<<20 {
			t.Errorf("essential holds only %dB -- the materialised files did not seal", essB)
		}
		if essB > 16<<20 {
			t.Errorf("essential holds %dB for ~11MB of content -- bytes duplicated", essB)
		}
		if defB != 0 {
			t.Errorf("deferred holds %dB, want 0", defB)
		}
	})
}
