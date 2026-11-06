package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261006-12: the OTA summary. These pin the notes format and its wording rule, the walk from the offered version
// back to the running one, the reply the gate reads, and that every notes file committed in the tree is valid and
// chained.

const goodNotes = "version 0.5.44\nprevious 0.5.43\n- The update screen shows what changed.\n- A text sent during sign-in is no longer shown twice.\n"

func TestParseOtaNotes(t *testing.T) {
	n, err := parseOtaNotes(goodNotes)
	if err != nil || n.Version != "0.5.44" || n.Previous != "0.5.43" || len(n.Points) != 2 {
		t.Fatalf("good notes: %+v, %v", n, err)
	}
	if _, err := parseOtaNotes(strings.ReplaceAll(goodNotes, "\n", "\r\n")); err != nil {
		t.Errorf("CRLF line endings refused: %v", err)
	}
	long := strings.Repeat("x", otaNotesMaxPoint+1)
	for why, text := range map[string]string{
		"no version line":        "previous 0.5.43\n- a\n- b\n",
		"bad version":            "version five\nprevious 0.5.43\n- a\n",
		"no previous line":       "version 0.5.44\n- a\n- b\n",
		"previous not older":     "version 0.5.44\nprevious 0.5.44\n- a\n",
		"previous newer":         "version 0.5.44\nprevious 0.6.0\n- a\n",
		"no points":              "version 0.5.44\nprevious 0.5.43\n",
		"not a point":            "version 0.5.44\nprevious 0.5.43\nA sentence.\n",
		"empty point":            "version 0.5.44\nprevious 0.5.43\n- \n",
		"too many points":        "version 0.5.44\nprevious 0.5.43\n" + strings.Repeat("- a\n", otaNotesMaxPoints+1),
		"point too long":         "version 0.5.44\nprevious 0.5.43\n- " + long + "\n",
		"control character":      "version 0.5.44\nprevious 0.5.43\n- a\tb\n",
		"over the size cap":      "version 0.5.44\nprevious 0.5.43\n" + strings.Repeat("- "+strings.Repeat("y", 100)+"\n", 25),
		"privacy claim":          "version 0.5.44\nprevious 0.5.43\n- Better privacy for your texts.\n",
		"security claim":         "version 0.5.44\nprevious 0.5.43\n- Security fixes.\n",
		"encryption claim":       "version 0.5.44\nprevious 0.5.43\n- Your photos are now encrypted.\n",
		"protection claim":       "version 0.5.44\nprevious 0.5.43\n- Protects your messages.\n",
		"cannot-see claim":       "version 0.5.44\nprevious 0.5.43\n- We can't see your data.\n",
		"anonymity claim":        "version 0.5.44\nprevious 0.5.43\n- Reports are anonymous.\n",
		"safety claim, any case": "version 0.5.44\nprevious 0.5.43\n- SAFER sign-in.\n",
	} {
		if _, err := parseOtaNotes(text); err == nil {
			t.Errorf("%s: accepted", why)
		}
	}
}

func TestWalkOtaNotes(t *testing.T) {
	pub := map[string]*otaNotes{}
	for _, v := range [][2]string{{"0.5.45", "0.5.44"}, {"0.5.44", "0.5.43"}, {"0.5.43", "0.5.42"}} {
		pub[v[0]] = &otaNotes{Version: v[0], Previous: v[1], Points: []string{"p"}}
	}
	fetch := func(v string) (*otaNotes, error) { return pub[v], nil }
	versions := func(c []*otaNotes) string {
		var s []string
		for _, n := range c {
			s = append(s, n.Version)
		}
		return strings.Join(s, ",")
	}
	for _, c := range []struct {
		offered, running, want string
		more                   bool
	}{
		{"0.5.45", "0.5.42", "0.5.45,0.5.44,0.5.43", false}, // the chain reaches the running version exactly
		{"0.5.45", "0.5.44", "0.5.45", false},
		{"0.5.45", "0.5.40", "0.5.45,0.5.44,0.5.43", true}, // 0.5.42 predates the notes: earlier changes undescribed
		{"0.5.45", "0.5.45", "", false},                    // nothing newer
		{"0.5.46", "0.5.42", "", true},                     // the offered version has no notes
	} {
		chain, more := walkOtaNotes(fetch, c.offered, c.running)
		if versions(chain) != c.want || more != c.more {
			t.Errorf("offered %s running %s: chain %q more %v, want %q %v", c.offered, c.running, versions(chain), more, c.want, c.more)
		}
	}
	if chain, more := walkOtaNotes(func(string) (*otaNotes, error) { return nil, errors.New("offline") }, "0.5.45", "0.5.42"); len(chain) != 0 || !more {
		t.Error("a failed fetch must leave the walk incomplete, not silently complete")
	}
	// The cap: a phone far behind gets the newest otaNotesMaxWalk and "and earlier changes".
	deep := func(v string) (*otaNotes, error) {
		var x int
		for _, c := range strings.Split(v, ".")[2:] {
			for _, d := range c {
				x = x*10 + int(d-'0')
			}
		}
		return &otaNotes{Version: v, Previous: "0.5." + itoa(x-1), Points: []string{"p"}}, nil
	}
	if chain, more := walkOtaNotes(deep, "0.5.60", "0.5.1"); len(chain) != otaNotesMaxWalk || !more {
		t.Errorf("deep chain: %d versions, more %v; want %d and more", len(chain), more, otaNotesMaxWalk)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

// fetchOtaNotes reads the ref, then the blob, and refuses a blob that does not hash to its name or describes another
// version.
func TestFetchOtaNotesVerifies(t *testing.T) {
	body := []byte(goodNotes)
	sum := sha256.Sum256(body)
	h := hex.EncodeToString(sum[:])
	refs := map[string]string{"ota/lynx/notes-0.5.44": h, "ota/lynx/notes-0.5.99": h, "ota/pixel/notes-0.5.44": "ab" + h[2:]} // pixel: the right version, under a name its content does not hash to
	blobs := map[string][]byte{h: body, "ab" + h[2:]: body}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ref, ok := strings.CutPrefix(r.URL.Path, "/ref/"); ok {
			if v, ok := refs[ref]; ok {
				w.Write([]byte(v))
				return
			}
		}
		if k, ok := strings.CutPrefix(r.URL.Path, "/blob/"); ok {
			if v, ok := blobs[k]; ok {
				w.Write(v)
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	if n, err := fetchOtaNotes(srv.URL, "lynx", "0.5.44"); err != nil || n == nil || len(n.Points) != 2 {
		t.Fatalf("published notes: %+v, %v", n, err)
	}
	if n, err := fetchOtaNotes(srv.URL, "lynx", "0.5.43"); n != nil || err != nil {
		t.Errorf("no notes published must be (nil, nil), got %+v, %v", n, err)
	}
	if _, err := fetchOtaNotes(srv.URL, "lynx", "0.5.99"); err == nil {
		t.Error("notes filed under 0.5.99 that describe 0.5.44 were accepted")
	}
	if _, err := fetchOtaNotes(srv.URL, "pixel", "0.5.44"); err == nil {
		t.Error("a blob that does not hash to its name was accepted")
	}
}

func TestOtaNotesReply(t *testing.T) {
	own, _ := parseOtaNotes("version 0.5.43\nprevious 0.5.42\n- Mine.\n")
	otaNotesMu.Lock()
	otaNotesOffered, otaNotesChain, otaNotesMore = "0.5.45", []*otaNotes{
		{Version: "0.5.45", Points: []string{"A."}}, {Version: "0.5.44", Points: []string{"B.", "C."}}}, true
	otaNotesMu.Unlock()
	t.Cleanup(func() {
		otaNotesMu.Lock()
		otaNotesOffered, otaNotesChain, otaNotesMore = "", nil, false
		otaNotesMu.Unlock()
	})
	var b strings.Builder
	writeOtaNotesReply(&b, "0.5.43", own, true, "0.5.45")
	want := "RUNNING 0.5.43\nNOTE Mine.\nOFFERED 0.5.45\nNOTE A.\nOFFERED 0.5.44\nNOTE B.\nNOTE C.\nMORE\nEND\n"
	if b.String() != want {
		t.Fatalf("reply:\n%s\nwant:\n%s", b.String(), want)
	}
	b.Reset()
	writeOtaNotesReply(&b, "0.5.43", nil, false, "0.5.45")
	if b.String() != "RUNNING 0.5.43\nEND\n" {
		t.Errorf("no update available must carry no offered notes: %q", b.String())
	}
	b.Reset()
	writeOtaNotesReply(&b, "0.5.43", nil, true, "0.5.46") // the cache is for another offer
	if strings.Contains(b.String(), "OFFERED") {
		t.Errorf("notes walked for a different offer were served: %q", b.String())
	}
}

func TestBakedOtaNotesMustDescribeTheRunningImage(t *testing.T) {
	p := filepath.Join(t.TempDir(), "notes")
	os.WriteFile(p, []byte("version 0.5.43\nprevious 0.5.42\n- Mine.\n"), 0o644)
	if bakedOtaNotes(p, "0.5.43") == nil {
		t.Error("the image's own notes were not read")
	}
	if bakedOtaNotes(p, "0.5.44") != nil {
		t.Error("notes for another version were shown as this image's")
	}
	if bakedOtaNotes(filepath.Join(t.TempDir(), "absent"), "0.5.43") != nil {
		t.Error("absent notes must be nil")
	}
}

// Every notes file in the tree is valid, named for the version it describes, and -- except the first -- links to a
// version whose notes are also in the tree. This is what makes a bad set fail at commit rather than at publish.
func TestCommittedOtaNotesAreValidAndChained(t *testing.T) {
	dir := filepath.Join("..", "vendor-common", "etc", "ota-notes")
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("%s: %v", dir, err)
	}
	have := map[string]*otaNotes{}
	for _, e := range ents {
		if e.Name() == "README" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		n, err := parseOtaNotes(string(b))
		if err != nil {
			t.Errorf("%s: %v", e.Name(), err)
			continue
		}
		if n.Version != e.Name() {
			t.Errorf("%s describes version %s", e.Name(), n.Version)
		}
		have[n.Version] = n
	}
	if len(have) == 0 {
		t.Fatal("no notes files in the tree")
	}
	first := ""
	for v, n := range have {
		if have[n.Previous] == nil {
			if first != "" {
				t.Errorf("two chain starts (%s and %s): every notes file but the first must link to one in the tree", first, v)
			}
			first = v
		}
	}
	stamp, _ := os.ReadFile(filepath.Join("..", "vendor-common", "etc", "nowhere-ota-version"))
	if s := strings.TrimSpace(string(stamp)); have[s] == nil {
		t.Logf("no notes yet for the tree's stamp %s (required at release: verify-release.sh)", s)
	}
}

// The wiring a unit test cannot reach: the refresh walks the chain (so OTA-NOTES has something to serve), the verb is
// served, and both editions stage and bake the image's own notes.
func TestOtaNotesAreWired(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	main := read("main.go")
	refresh := main[strings.Index(main, "func refreshOtaCache() {"):]
	refresh = refresh[:strings.Index(refresh, "\n}\n")]
	if !strings.Contains(refresh, `refreshOtaNotes("s3", latest, runningOtaVersion())`) {
		t.Error("refreshOtaCache no longer walks the notes chain -- OTA-NOTES would never have offered notes to serve")
	}
	if !strings.Contains(main, `if name == "OTA-NOTES" {`) {
		t.Error("the OTA-NOTES verb is gone")
	}
	for _, ed := range []string{"endospore", "diaspore"} {
		sv := read(filepath.Join("..", "..", "editions", ed, "build", "stage-vendor.sh"))
		if !strings.Contains(sv, `install -m 0644 "$DEST/etc/ota-notes/$OTA_STAMP" "$DEST/etc/nowhere-ota-notes"`) ||
			!strings.Contains(sv, `rm -rf "$DEST/etc/ota-notes"`) {
			t.Errorf("%s stage-vendor.sh no longer stages the image's own notes", ed)
		}
		mk := read(filepath.Join("..", "..", "editions", ed, ed+".mk"))
		if !strings.Contains(mk, "vendor/"+ed+"/etc/nowhere-ota-notes:$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere-ota-notes") {
			t.Errorf("%s.mk no longer bakes /system/etc/nowhere-ota-notes", ed)
		}
	}
}
