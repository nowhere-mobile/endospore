package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

// NWP-20261123-14 (h51 #4 A1): "What's using your space" folded every user file into one MediaBytes, and the store
// side priced packages only, so the user's media sat inside StoreOther ("Recent backups and shared data"). A
// store-heavy Download, 373 MB in the store and ~0 on the phone, was invisible and its plan cost read as backups.
// These tests run the walk, mediaFolderStore, storePkgBytes and withStoreBytes themselves.

// sfFolders indexes a reply's folder rows by name.
func sfFolders(fs []storageFolder) map[string]storageFolder {
	out := map[string]storageFolder{}
	for _, f := range fs {
		out[f.Name] = f
	}
	return out
}

func TestStorageFoldersWalkNamesEachTopLevelFolder(t *testing.T) {
	root := t.TempDir()
	user := filepath.Join(root, "data", "user", "10")
	media := filepath.Join(root, "data", "media", "10")
	ext := filepath.Join(user, chooserPkg, "files", ".nowhere-media-ext", ".under")
	ce := filepath.Join(user, chooserPkg, "files", ".nowhere-media", ".under")
	mkfile(t, filepath.Join(media, "Download", "a"), 300)
	mkfile(t, filepath.Join(media, "DCIM", "c", "x"), 500)
	mkfile(t, filepath.Join(media, "top.bin"), 70)
	mkfile(t, filepath.Join(media, "Movies.2024", "m.mp4"), 33)
	mkfile(t, filepath.Join(media, "Android", "data", "com.example.app", "f"), 900)
	mkfile(t, filepath.Join(ext, underLeaf("Download"), "b"), 40)                // an overlaid Download's real file
	mkfile(t, filepath.Join(ce, underLeaf(chooserPkg+"/files/x"), "y"), 6)       // a CE-cache user file: no folder
	mkfile(t, filepath.Join(ext, underLeaf("Android/data/"+chooserPkg), "z"), 4) // the user's, under Android/: no folder

	b := collectStorageBreakdownAt(root, "10", nil)
	got := sfFolders(b.Folders)
	want := map[string]int64{"Download": 340, "DCIM": 500, "": 80, "Movies.2024": 33}
	if len(got) != len(want) {
		t.Errorf("folders = %+v, want exactly %v", b.Folders, want)
	}
	for name, n := range want {
		if got[name].Bytes != n {
			t.Errorf("folder %q = %d bytes, want %d (folders %+v)", name, got[name].Bytes, n, b.Folders)
		}
	}
	if _, ok := got["Android"]; ok {
		t.Errorf("Android is app data, never a user folder: %+v", b.Folders)
	}
	var sum int64
	for _, f := range b.Folders {
		sum += f.Bytes
	}
	if sum != b.MediaBytes {
		t.Errorf("sum(folders) = %d, MediaBytes = %d: the folder rows must add up to the one row they replace", sum, b.MediaBytes)
	}
	var app int64
	for _, a := range b.Apps {
		if a.Pkg == "com.example.app" {
			app = a.Bytes
		}
		if a.Pkg == "Movies.2024" {
			t.Errorf("a dotted folder became an app row: %+v", a)
		}
	}
	if app != 900 {
		t.Errorf("com.example.app = %d, want 900 (Android/data stays on its app)", app)
	}
	for i := 1; i < len(b.Folders); i++ {
		p, q := b.Folders[i-1], b.Folders[i]
		if p.Bytes < q.Bytes || (p.Bytes == q.Bytes && p.Name > q.Name) {
			t.Errorf("folders not in Bytes-desc, Name-asc order: %+v", b.Folders)
		}
	}
}

func TestMediaFolderStoreSumsEssAndDeferredPerFolder(t *testing.T) {
	chunks := []string{"c0", "c1", "c2", "c3", "c4", "c5"}
	good := func() chunkManifest {
		return chunkManifest{
			EssIdx: true,
			Chunks: chunks,
			Sizes:  []int64{10, 20, 30, 40, 50, 60},
			Ess: map[string]essRegion{
				"Download/a":       {S: 0, E: 2},
				"DCIM/x":           {S: 2, E: 3},
				"top.bin":          {S: 3, E: 4},
				"Android/data/p/f": {S: 4, E: 6},
			},
			Deferred: map[string]deferredFile{
				"Download/big":      {Sz: []int64{100, 5}},
				"Android/media/p/m": {Sz: []int64{999}},
			},
		}
	}
	got, ok := mediaFolderStore(good())
	if !ok {
		t.Fatal("an indexed head with parallel Sizes must be measured")
	}
	want := map[string]int64{"Download": 135, "DCIM": 30, "": 40}
	if len(got) != len(want) {
		t.Errorf("mediaFolderStore = %v, want %v (an Android/ rel counts in no folder)", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("folder %q = %d, want %d (all %v)", k, got[k], v, got)
		}
	}
	for name, mut := range map[string]func(*chunkManifest){
		"no per-file index (EssIdx false)": func(m *chunkManifest) { m.EssIdx = false },
		"Sizes shorter than Chunks":        func(m *chunkManifest) { m.Sizes = m.Sizes[:5] },
		"a span starting before 0":         func(m *chunkManifest) { m.Ess["DCIM/x"] = essRegion{S: -1, E: 1} },
		"a span ending past Chunks":        func(m *chunkManifest) { m.Ess["DCIM/x"] = essRegion{S: 2, E: 7} },
		"a span with S > E":                func(m *chunkManifest) { m.Ess["DCIM/x"] = essRegion{S: 3, E: 2} },
		"a bad span on an Android/ rel":    func(m *chunkManifest) { m.Ess["Android/data/p/f"] = essRegion{S: 4, E: 9} },
	} {
		m := good()
		mut(&m)
		if got, ok := mediaFolderStore(m); ok {
			t.Errorf("%s: measured %v, want not measured", name, got)
		}
	}
}

// sfStubSeams replaces the three store-reading seams for one test.
func sfStubSeams(t *testing.T, per map[string]int64, folders map[string]int64, foldersOK bool, total int64) {
	t.Helper()
	oldP, oldF, oldT := storePkgBytesOf, storeFolderBytesOf, footprintOf
	storePkgBytesOf = func(base, profile, pass string, se []byte) (map[string]int64, map[string]bool, bool, bool) {
		return per, map[string]bool{}, true, true
	}
	storeFolderBytesOf = func(base, profile, pass string, se []byte) (map[string]int64, bool) {
		return folders, foldersOK
	}
	footprintOf = func(base, profile, pass string, se []byte) (map[string]int64, bool) {
		return map[string]int64{"all": total}, true
	}
	t.Cleanup(func() { storePkgBytesOf, storeFolderBytesOf, footprintOf = oldP, oldF, oldT })
}

const sfWorkerJSON = `{"apps":[{"pkg":"com.a","bytes":100,"mode":"installed"}],"media_bytes":370,` +
	`"cache_bytes":0,"total_bytes":470,"blind":0,"folders":[{"name":"Download","bytes":300},{"name":"","bytes":70}]}`

func TestWithStoreBytesFoldersReconcile(t *testing.T) {
	merge := func(t *testing.T) storageBreakdown {
		t.Helper()
		got, err := withStoreBytes(sfWorkerJSON, "sfreconcile", "sf-pass-not-real", nil)
		if err != nil {
			t.Fatal(err)
		}
		var b storageBreakdown
		if err := json.Unmarshal([]byte(got), &b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	t.Run("measured", func(t *testing.T) {
		sfStubSeams(t, map[string]int64{"com.a": 40}, map[string]int64{"Download": 135, "": 40, "Pictures": 25}, true, 300)
		b := merge(t)
		if !b.FoldersMeasured {
			t.Error("FoldersMeasured = false with a measured #media index")
		}
		got := sfFolders(b.Folders)
		if f := got["Pictures"]; f.Bytes != 0 || f.Store != 25 {
			t.Errorf("a folder only the store holds needs a Bytes-0 row with its plan cost, got %+v (all %+v)", f, b.Folders)
		}
		if got["Download"].Store != 135 || got["Download"].Bytes != 300 || got[""].Store != 40 {
			t.Errorf("folder rows %+v, want Download 300/135 and \"\" 70/40", b.Folders)
		}
		var apps, folders int64
		for _, a := range b.Apps {
			apps += a.Store
		}
		for _, f := range b.Folders {
			folders += f.Store
		}
		if apps+folders+b.StoreOther != b.StoreTotal || b.StoreOther != 60 {
			t.Errorf("apps %d + folders %d + other %d != total %d (want other 60): the plan column must add up",
				apps, folders, b.StoreOther, b.StoreTotal)
		}
		if b.MediaBytes != 370 {
			t.Errorf("MediaBytes = %d, want the walk's 370 unchanged", b.MediaBytes)
		}
	})
	t.Run("not measured", func(t *testing.T) {
		sfStubSeams(t, map[string]int64{"com.a": 40}, nil, false, 300)
		b := merge(t)
		if b.FoldersMeasured {
			t.Error("FoldersMeasured = true with no #media index")
		}
		for _, f := range b.Folders {
			if f.Store != 0 {
				t.Errorf("an unmeasured folder carries a store figure: %+v", f)
			}
		}
		if len(b.Folders) != 2 {
			t.Errorf("the walk's folder rows must pass through unchanged, got %+v", b.Folders)
		}
		if b.StoreOther != 260 {
			t.Errorf("StoreOther = %d, want 260 (today's store side: total 300 - apps 40)", b.StoreOther)
		}
	})
	t.Run("folders measured, packages not", func(t *testing.T) {
		// Only the user's own files are sealed: no head carries a Pkg index, so storePkgBytes reports not measured.
		// The #media index still prices the folders, and a store-only Download still gets its row.
		sfStubSeams(t, nil, map[string]int64{"Download": 373}, true, 400)
		storePkgBytesOf = func(base, profile, pass string, se []byte) (map[string]int64, map[string]bool, bool, bool) {
			return map[string]int64{}, map[string]bool{}, false, false
		}
		got, err := withStoreBytes(`{"apps":[],"media_bytes":0}`, "sfnopkg", "sf-pass-not-real", nil)
		if err != nil {
			t.Fatal(err)
		}
		var b storageBreakdown
		if err := json.Unmarshal([]byte(got), &b); err != nil {
			t.Fatal(err)
		}
		if !b.FoldersMeasured {
			t.Fatalf("indexed media without a Pkg index lost its folder figures: %s", got)
		}
		if f := sfFolders(b.Folders)["Download"]; f.Bytes != 0 || f.Store != 373 {
			t.Errorf("a store-only Download needs a Bytes-0 row with its plan cost, got %+v (reply %s)", f, got)
		}
		if b.StoreMeasured {
			t.Error("StoreMeasured = true with no Pkg index: the app rows would read as measured and free")
		}
		if b.StoreTotal != 400 || b.StoreOther != 27 {
			t.Errorf("StoreTotal %d, StoreOther %d; want 400 and 27 (folders + other == total)", b.StoreTotal, b.StoreOther)
		}
	})
}

// sfPlantMedia writes a legacy bare #media head carrying m for (name, pass) in base.
func sfPlantMedia(t *testing.T, base, name, pass string, m chunkManifest) {
	t.Helper()
	j, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	scope := name + "#media"
	h := postBlob(base, seal(deriveKey(scope, pass), append(append([]byte{}, cdcMagic...), j...)))
	putRef(base, profileRefV2(scope, pass), h)
}

func sfStoreEnv(t *testing.T) string {
	t.Helper()
	base := newHTTPStore(t)
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SE_SECRET", "")
	return base
}

func TestStorageFoldersDottedFolderIsAFolderNotAnApp(t *testing.T) {
	t.Run("indexed", func(t *testing.T) {
		base := sfStoreEnv(t)
		name, pass := "sfdotted", "sf dotted passphrase"
		sfPlantMedia(t, base, name, pass, chunkManifest{
			Version: 1, Chunks: []string{"c0", "c1"}, Sizes: []int64{17, 29}, EssIdx: true,
			Ess:      map[string]essRegion{"Movies.2024/m.mp4": {S: 0, E: 1}, "Android/data/com.app/f": {S: 1, E: 2}},
			Deferred: map[string]deferredFile{"Movies.2024/big.mp4": {Sz: []int64{70}}},
			Pkg:      map[string]int64{"Movies.2024": 11, "com.app": 22},
		})
		per, _, measured, _ := storePkgBytes(base, name, pass, nil)
		if !measured {
			t.Fatal("control: the planted #media head was not read")
		}
		if v, ok := per["Movies.2024"]; ok {
			t.Errorf("a dotted folder is billed to an app row of %d bytes: its bytes are its folder's", v)
		}
		if per["com.app"] != 22 {
			t.Errorf("com.app = %d, want 22 (an app's #media bytes stay on its row)", per["com.app"])
		}
		fs, ok := storeFolderBytes(base, name, pass, nil)
		if !ok || fs["Movies.2024"] != 17+70 {
			t.Errorf("storeFolderBytes = %v, %v; want Movies.2024 = %d, measured", fs, ok, 17+70)
		}
	})
	t.Run("deferred only", func(t *testing.T) {
		base := sfStoreEnv(t)
		name, pass := "sfdottedd", "sf dotted deferred passphrase"
		sfPlantMedia(t, base, name, pass, chunkManifest{
			Version: 1, Chunks: []string{"c0"}, Sizes: []int64{5},
			Deferred: map[string]deferredFile{"Movies.2024/big.mp4": {Sz: []int64{70}}, "Android/media/com.app/m": {Sz: []int64{9}}},
			Pkg:      map[string]int64{"com.app": 22},
		})
		per, _, measured, _ := storePkgBytes(base, name, pass, nil)
		if !measured {
			t.Fatal("control: the planted #media head was not read")
		}
		if v, ok := per["Movies.2024"]; ok {
			t.Errorf("a dotted folder's deferred bytes are billed to an app row of %d bytes", v)
		}
		if per["com.app"] != 22+9 {
			t.Errorf("com.app = %d, want %d (its essential and deferred #media bytes)", per["com.app"], 22+9)
		}
		if _, ok := storeFolderBytes(base, name, pass, nil); ok {
			t.Error("a head without the per-file index must read as not measured for folders")
		}
	})
}
