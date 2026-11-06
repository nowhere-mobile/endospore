package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #84 P1: classifyDeferred is the SPLIT policy -- big bulk media in known media subtrees defers; everything
// else (small, unknown-location, or login/state-critical) stays essential. A misclassification must only ever
// make login slower, never break it, so the "unknown -> essential" and deny-list behaviors are the crux.
func TestClassifyDeferred(t *testing.T) {
	big := int64(32 << 20) // comfortably over the 8 MiB floor
	huge := int64(512 << 20)
	small := int64(4 << 20) // under the floor

	cases := []struct {
		rel  string
		size int64
		want bool
		why  string
	}{
		// the worked example: OrganicMaps offline maps -> deferred
		{"app.organicmaps/files/260527/China_Hebei.mwm", huge, true, "big map in app files/"},
		{"com.example/files/models/llm.bin", big, true, "big ML model in files/"},
		{"media/0/DCIM/Camera/VID_0001.mp4", huge, true, "big video in DCIM"},
		{"media/0/Download/movie.mkv", huge, true, "big download"},
		{"media/0/Pictures/pano.jpg", big, true, "big picture"},

		// too small -> essential regardless of location
		{"app.organicmaps/files/tiny.mwm", small, false, "under the size floor"},

		// login/state-critical -> NEVER deferred even if big + in a media dir
		{"com.example/databases/accounts.db", huge, false, "sqlite DB (deny dir)"},
		{"com.example/files/creds.keystore", huge, false, "keystore (deny ext)"},
		{"com.example/files/big.db-wal", big, false, "sqlite WAL (deny ext)"},
		{"com.example/shared_prefs/prefs_huge.xml", big, false, "shared_prefs (deny dir)"},

		// big but NOT in a known media subtree -> essential (conservative)
		{"com.example/app_webview/GPUCache/blob", huge, false, "unknown location -> essential"},
		{"com.example/lib/native.so", big, false, "code, not media"},

		// app-essential code/metadata (il2cpp) -> NEVER deferred even if big + in files/ (DIA-20260730: deferring
		// it broke Toon Blast launch on an incomplete restore). Bulk asset bundles under the same app still defer.
		{"net.peakgames.toonblast/files/il2cpp/Metadata/global-metadata.dat", huge, false, "il2cpp metadata: app-essential, keep eager"},
		{"com.example/files/il2cpp/unity.ver", big, false, "il2cpp version blob: keep eager"},
		{"net.peakgames.toonblast/files/ContentDownload/pack01.ab", huge, true, "asset bundle: still deferrable"},

		// NWP-20260923-01: an app's own LOGS -> NEVER deferred. Deferring them mounted a FUSE overlay over
		// com.whatsapp/files/Logs that odrestore cannot write through (endospore_priv is read-only on fuse), so
		// every hand-back failed and every tap re-materialised the app (ticket NW-aa348ffb98fd). Both paths are
		// the ones from that ticket, capital-L included: the entry is lowercase and the SUBJECT is lowercased,
		// so this pins that "/logs/" really matches the directory WhatsApp actually creates.
		{"com.whatsapp/files/Logs/whatsapp.log", big, false, "app log: deny dir"},
		{"com.whatsapp/files/Logs/whatsapp-2026-09-23.1.log.gz", big, false, "rotated log: covered by the DIR -- no suffix entry could"},
		// guard-the-guard, the three ways a log rule overreaches. It must stay SEGMENT-anchored (leading AND
		// trailing slash), or it swallows unrelated app media -- and the same app's other files/ must still defer,
		// or this has quietly become "never defer WhatsApp", which is not the decision anyone made.
		{"com.whatsapp/files/crashlogs/dump.bin", big, true, "segment-anchored: crashlogs/ is not logs/"},
		{"com.example/files/models/logs.bin", big, true, "a FILE named logs* is not the /logs/ dir"},
		{"com.whatsapp/files/Avatars/pack.bin", big, true, "same app, non-log files/ still defers"},
	}
	for _, c := range cases {
		if got := classifyDeferred(c.rel, c.size); got != c.want {
			t.Errorf("classifyDeferred(%q, %d) = %v, want %v (%s)", c.rel, c.size, got, c.want, c.why)
		}
	}
}

// The size floor is env-tunable, and 0/garbage falls back to the default.
func TestMediaMinBytes(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_MIN", "")
	if mediaMinBytes() != 8<<20 {
		t.Fatalf("default should be 8 MiB, got %d", mediaMinBytes())
	}
	t.Setenv("NOWHERE_MEDIA_MIN", "1048576") // 1 MiB
	if mediaMinBytes() != 1<<20 {
		t.Fatalf("env override failed: got %d", mediaMinBytes())
	}
	// with a 1 MiB floor, a 4 MiB map now defers
	if !classifyDeferred("app.organicmaps/files/x.mwm", 4<<20) {
		t.Fatal("a 4 MiB map should defer under a 1 MiB floor")
	}
	t.Setenv("NOWHERE_MEDIA_MIN", "bogus")
	if mediaMinBytes() != 8<<20 {
		t.Fatalf("garbage env should fall back to default, got %d", mediaMinBytes())
	}
}

// The deferred manifest field is omitempty -> a profile with no deferred media serializes byte-identical to a
// pre-#84 manifest (so #85 Sizes-style back-compat holds).
func TestManifestDeferredOmitempty(t *testing.T) {
	m := chunkManifest{Version: 2, Chunks: []string{"a", "b"}, Sizes: []int64{1, 2}}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "deferred") {
		t.Fatalf("empty Deferred must be omitted from JSON, got %s", b)
	}
	// but a populated one round-trips
	m.Deferred = map[string]deferredFile{"a/files/x.mwm": {Chunks: []string{"h1", "h2"}, Size: 99, Mode: 0o644, MTime: 7}}
	b2, _ := json.Marshal(m)
	var back chunkManifest
	if err := json.Unmarshal(b2, &back); err != nil {
		t.Fatal(err)
	}
	if d, ok := back.Deferred["a/files/x.mwm"]; !ok || d.Size != 99 || len(d.Chunks) != 2 {
		t.Fatalf("deferred entry did not round-trip: %+v", back.Deferred)
	}
}

// #129 P1: classifyTier layers the tier on top of classifyDeferred. Non-media/state-critical is always
// essential (never demoted); a #108 pin forces essential; a per-profile override beats the curated default;
// an unconfigured app falls to the curated default (on-demand unless curated, e.g. maps -> prefetch).
func TestClassifyTier(t *testing.T) {
	huge := int64(512 << 20)
	small := int64(4 << 20)
	pins := map[string]bool{"app.pinned": true}
	tiers := map[string]mediaTier{"app.custom": tierPrefetch, "app.organicmaps": tierOnDemand} // override curated

	// curated default with NO profile config: OrganicMaps prefetches, an unknown app is on-demand.
	if got := classifyTier("app.organicmaps/files/China.mwm", huge, nil, nil); got != tierPrefetch {
		t.Errorf("curated organicmaps default = %d, want prefetch(%d)", got, tierPrefetch)
	}
	if got := classifyTier("app.unknownmaps/files/x.mwm", huge, nil, nil); got != tierOnDemand {
		t.Errorf("unknown app default = %d, want ondemand(%d)", got, tierOnDemand)
	}

	cases := []struct {
		rel  string
		size int64
		want mediaTier
		why  string
	}{
		{"com.example/databases/x.db", huge, tierEssential, "state-critical deny-dir -> essential, never deferred"},
		{"com.example/files/x.bin", small, tierEssential, "under the size floor -> essential"},
		{"com.example/lib/native.so", huge, tierEssential, "big but not media -> essential"},
		{"app.pinned/files/big.mwm", huge, tierEssential, "#108 pin forces essential (beats config + curated)"},
		{"app.custom/files/big.mwm", huge, tierPrefetch, "per-profile override -> prefetch"},
		{"app.organicmaps/files/big.mwm", huge, tierOnDemand, "per-profile override BEATS the curated prefetch"},
		{"app.unknownmaps/files/big.mwm", huge, tierOnDemand, "no pin/override/curated -> on-demand default"},
		// NWP-20260923-01: the deny must win at the TIER layer too, not just in classifyDeferred -- and it must
		// beat a per-profile override, which is the strongest user signal short of a pin. "app.custom" is
		// configured for prefetch above; its logs must still seal essential.
		{"com.whatsapp/files/Logs/whatsapp.log", huge, tierEssential, "app logs deny-dir -> essential"},
		{"app.custom/files/Logs/trace.log", huge, tierEssential, "deny beats a per-profile prefetch override"},
	}
	for _, c := range cases {
		if got := classifyTier(c.rel, c.size, tiers, pins); got != c.want {
			t.Errorf("classifyTier(%q, %d) = %d, want %d (%s)", c.rel, c.size, got, c.want, c.why)
		}
	}
}

// loadTiers parses the roaming per-profile override file; comments/blank/malformed/unknown-tier lines are
// skipped; a missing file loads nil (curated defaults apply).
func TestLoadTiers(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, filepath.FromSlash(tierFileRel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "# a comment\n\napp.organicmaps prefetch\napp.photos ondemand\napp.docs essential\nmalformed line here\napp.bad bogustier\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	m := loadTiers(dir)
	if m["app.organicmaps"] != tierPrefetch || m["app.photos"] != tierOnDemand || m["app.docs"] != tierEssential {
		t.Fatalf("loadTiers parsed wrong: %+v", m)
	}
	if _, ok := m["app.bad"]; ok {
		t.Fatalf("bogus tier must be skipped: %+v", m)
	}
	if len(m) != 3 {
		t.Fatalf("expected 3 valid entries, got %d: %+v", len(m), m)
	}
	if loadTiers(t.TempDir()) != nil {
		t.Fatal("missing tier file should load nil")
	}
}

// The manifest Tier field is omitempty and on-demand==0, so an on-demand deferred file (and every pre-#129
// manifest) stays byte-identical; a prefetch file records tr:2 and round-trips.
func TestManifestTierOmitempty(t *testing.T) {
	m := chunkManifest{Version: 2, Chunks: []string{"a"}, Deferred: map[string]deferredFile{
		"a/files/x.mwm": {Chunks: []string{"h1"}, Size: 9, Tier: int(tierOnDemand)},
	}}
	b, _ := json.Marshal(m)
	if strings.Contains(string(b), `"tr"`) {
		t.Fatalf("Tier=0 (on-demand) must be omitted from JSON, got %s", b)
	}
	m.Deferred["a/files/y.mwm"] = deferredFile{Chunks: []string{"h2"}, Size: 9, Tier: int(tierPrefetch)}
	b2, _ := json.Marshal(m)
	if !strings.Contains(string(b2), `"tr":2`) {
		t.Fatalf("Tier=2 (prefetch) must be recorded, got %s", b2)
	}
	var back chunkManifest
	if err := json.Unmarshal(b2, &back); err != nil {
		t.Fatal(err)
	}
	if back.Deferred["a/files/y.mwm"].Tier != int(tierPrefetch) {
		t.Fatalf("prefetch tier did not round-trip: %+v", back.Deferred)
	}
	if back.Deferred["a/files/x.mwm"].Tier != int(tierOnDemand) {
		t.Fatalf("on-demand tier should read back as 0: %+v", back.Deferred)
	}
}

// #129 metered-prefetch policy, NWP-20261005-08 form: the live session's value in the state dir, keyed by its uid.
// Absent -> false (Wi-Fi-only default); "<uid> 1" -> true for THAT uid only; anything else -> false.
func TestPrefetchMeteredFor(t *testing.T) {
	dest := t.TempDir()
	p := filepath.Join(dest, prefetchMeteredOut)
	if prefetchMeteredFor(dest, "10") {
		t.Fatal("absent must default to false (Wi-Fi-only)")
	}
	for _, c := range []struct {
		body, uid string
		want      bool
		why       string
	}{
		{"10 1\n", "10", true, "this session opted in"},
		{"10 1\n", "11", false, "an earlier session's opt-in must not carry to a new user"},
		{"10 1\n", "", false, "no session uid is never an opt-in"},
		{"10 0\n", "10", false, `"0" is Wi-Fi-only`},
		{"1\n", "10", false, "the pre-NWP-20261005-08 unkeyed form is not an opt-in"},
		{"10 1 x\n", "10", false, "a malformed line is not an opt-in"},
	} {
		if err := os.WriteFile(p, []byte(c.body), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := prefetchMeteredFor(dest, c.uid); got != c.want {
			t.Errorf("body %q uid %q: got %v, want %v -- %s", c.body, c.uid, got, c.want, c.why)
		}
	}
}

func TestSetPrefetchMeteredRoundTrips(t *testing.T) {
	dest := t.TempDir()
	if err := setPrefetchMetered(dest, "12", true); err != nil {
		t.Fatal(err)
	}
	if !prefetchMeteredFor(dest, "12") {
		t.Fatal("SET on must read back as on for the same session")
	}
	if prefetchMeteredFor(dest, "13") {
		t.Fatal("SET for one session must not read as on for another")
	}
	if err := setPrefetchMetered(dest, "12", false); err != nil {
		t.Fatal(err)
	}
	if prefetchMeteredFor(dest, "12") {
		t.Fatal("SET off must read back as off")
	}
}

// NWP-20261005-08: the daemon runs as `nowhere`, which MLS refuses search on /data/user/<N> (vold creates it at user
// N's level). The old GET-PREFETCH-METERED read the roamed user's file in place: an avc every 30 s and an opt-in that
// never took effect. Pin that neither verb block reads the per-user data dir again.
func TestPrefetchMeteredVerbsNeverReadUserData(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, verb := range []string{"GET-PREFETCH-METERED", "SET-PREFETCH-METERED"} {
		i := strings.Index(src, `if name == "`+verb+`" {`)
		if i < 0 {
			t.Fatalf("%s handler not found", verb)
		}
		end := strings.Index(src[i:], "\n\t}\n")
		if end < 0 {
			t.Fatalf("%s handler has no end", verb)
		}
		block := src[i : i+end]
		if !strings.Contains(block, "readRoamSession(dest)") {
			t.Fatalf("%s block did not capture as expected (control): %q", verb, block)
		}
		if strings.Contains(block, `"/data/user`) {
			t.Errorf("%s reads the roamed user's data dir in place -- MLS-refused for the daemon", verb)
		}
	}
}

// TestMediaCfgRoot pins the #media-scope config redirect: the external-media scope (src=/data/media/N) must
// resolve its per-app tier/pin/budget config from the CE dir /data/user/N (where the chooser writes it), while
// the CE scope and test/tmp paths pass through unchanged. This is the fix for "Auto tier ignored / offline maps
// never prefetch" (the #media seal + serve read pins/tiers/budget from a dir that never exists).
func TestMediaCfgRoot(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/data/media/10", "/data/user/10"},            // external-media scope -> CE
		{"/data/media/0", "/data/user/0"},              // user 0
		{"/data/user/10", "/data/user/10"},             // CE scope: unchanged
		{"/tmp/seal-test-xyz", "/tmp/seal-test-xyz"},   // VM/test tmp: unchanged
		{"/data/mediastore/10", "/data/mediastore/10"}, // not the media scope (no exact "/data/media/" prefix boundary)
	}
	for _, c := range cases {
		if got := mediaCfgRoot(c.in); got != c.want {
			t.Errorf("mediaCfgRoot(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The chooser's on-demand APK staging dir must never be served as a media overlay: the overlay lands on the
// directory MATERIALIZE-APP writes into, and the app can then never be materialised again for the whole
// session (Tesla, lynx 2026-08-25 -- chown { setattr } denied on dev="fuse", then EACCES opening the split).
// A sibling that merely SHARES THE PREFIX must still be served, which is why this is not a bare HasPrefix.
func TestAppCodeStagingIsNeverOverlaid(t *testing.T) {
	for _, tc := range []struct {
		dir  string
		want bool
	}{
		{"com.nowhere.chooser/files/.appcode", true},
		{"com.nowhere.chooser/files/.appcode/com.teslamotors.tesla", true},
		{"com.nowhere.chooser/files/.appcodex", false},
		{"com.nowhere.chooser/files/.appcodex/pkg", false},
		{"com.nowhere.chooser/files/.nowhere-media", false},
		{"Pictures", false},
		{"", false},
	} {
		if got := isAppCodeStagingDir(tc.dir); got != tc.want {
			t.Errorf("isAppCodeStagingDir(%q) = %v, want %v", tc.dir, got, tc.want)
		}
	}
}
