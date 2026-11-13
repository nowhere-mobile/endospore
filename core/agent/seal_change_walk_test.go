package main

// NWP-20261202-06: the change mode of sealdeltawalk (seal_change_walk.go), the input of the h62 #4 change test.
// Temp roots only; the state paths and the app dir point into the temp tree. test-seal-change-walk.sh --mutate
// re-breaks each rule and names the test below that convicts it.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

type scwTree struct {
	base   string
	roots  map[string]string
	since  int64
	state  string // the temp dir the state paths point into
	appDir string
}

// scwSetup builds a profile tree, an app dir with one child and the state files, all older than since. The
// caller edits the tree, calls scwAgeAll, then moves the paths it wants changed with scwNew.
func scwSetup(t *testing.T) *scwTree {
	t.Helper()
	base := t.TempDir()
	tr := &scwTree{
		base:   base,
		roots:  map[string]string{"vault": filepath.Join(base, "vault"), "de": filepath.Join(base, "de"), "media": filepath.Join(base, "media")},
		since:  time.Now().Unix(),
		state:  filepath.Join(base, "state"),
		appDir: filepath.Join(base, "app"),
	}
	for _, f := range []string{
		"vault/" + sealChangeSelfDir + "/nowhere-save-mode",
		"vault/" + sealChangeSelfDir + "/nowhere-nav",
		"vault/com.example.scw/files/notes.txt",
		"de/com.example.scw/shared_prefs/p.xml",
		"media/DCIM/scw.jpg",
		"app/~~scw==/com.example.scw-1==/base.apk",
		"state/settings_secure.xml",
		"state/bt_config.conf",
	} {
		scwWrite(t, filepath.Join(base, f))
	}
	oldPaths, oldApp := sealChangeStatePaths, sealChangeAppDir
	t.Cleanup(func() { sealChangeStatePaths, sealChangeAppDir = oldPaths, oldApp })
	sealChangeStatePaths = func(uid string) []string {
		return []string{filepath.Join(tr.state, "settings_secure.xml"), filepath.Join(tr.state, "bt_config.conf"), filepath.Join(tr.state, "accounts_ce.db-wal")}
	}
	sealChangeAppDir = tr.appDir
	return tr
}

func scwWrite(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// scwAgeAll sets every path under base to since-100.
func (tr *scwTree) scwAgeAll(t *testing.T) {
	t.Helper()
	old := time.Unix(tr.since-100, 0)
	filepath.Walk(tr.base, func(p string, _ os.FileInfo, err error) error {
		if err == nil {
			os.Chtimes(p, old, old)
		}
		return nil
	})
}

// scwNew sets each rel (under base) to since+10.
func (tr *scwTree) scwNew(t *testing.T, rels ...string) {
	t.Helper()
	nw := time.Unix(tr.since+10, 0)
	for _, r := range rels {
		if err := os.Chtimes(filepath.Join(tr.base, r), nw, nw); err != nil {
			t.Fatal(err)
		}
	}
}

func (tr *scwTree) walk(t *testing.T, sinceArg string) ([]byte, map[string]any, sealChangeWalkOut) {
	t.Helper()
	b := sealDeltaWalkJSON("10", sinceArg, tr.roots, map[string]string{}, map[string]sealDeltaIdxEnt{}, nil)
	var m map[string]any
	var o sealChangeWalkOut
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("not JSON: %s", b)
	}
	json.Unmarshal(b, &o)
	return b, m, o
}

func (tr *scwTree) change() string { return strconv.FormatInt(tr.since, 10) + " change" }

func TestSealChangeWalkC1NothingNew(t *testing.T) {
	tr := scwSetup(t)
	tr.scwAgeAll(t)
	_, m, o := tr.walk(t, tr.change())
	if m["mode"] != "change" {
		t.Fatalf("mode = %v, want change", m["mode"])
	}
	if o.ChangedFiles != 0 || o.ChangedDirs != 0 || o.StateChanged != 0 || o.AppsChanged != 0 || o.SelfSkipped != 0 || o.Blind != 0 || o.DeferredFiles != 0 || o.DeletedFiles != 0 {
		t.Fatalf("an unchanged tree counted something: %+v", o)
	}
}

func TestSealChangeWalkC2SmallDeleteMovesDir(t *testing.T) {
	tr := scwSetup(t)
	p := filepath.Join(tr.roots["vault"], "com.example.scw/files/small.tmp")
	scwWrite(t, p)
	os.Remove(p)
	tr.scwAgeAll(t)
	tr.scwNew(t, "vault/com.example.scw/files") // a delete moves only its dir's mtime
	_, _, o := tr.walk(t, tr.change())
	if o.ChangedDirs != 1 || o.ChangedFiles != 0 {
		t.Fatalf("a small file deleted: changedDirs=%d changedFiles=%d, want 1 and 0", o.ChangedDirs, o.ChangedFiles)
	}
}

func TestSealChangeWalkC3SelfWritesOnly(t *testing.T) {
	tr := scwSetup(t)
	d := "vault/" + sealChangeSelfDir
	for _, f := range []string{"nowhere-claims", "bt-bond-bt_config"} {
		scwWrite(t, filepath.Join(tr.base, d, f))
	}
	tr.scwAgeAll(t)
	tr.scwNew(t, d+"/nowhere-nav", d+"/nowhere-claims", d+"/bt-bond-bt_config", d)
	_, _, o := tr.walk(t, tr.change())
	if o.ChangedFiles != 0 || o.ChangedDirs != 0 || o.StateChanged != 0 || o.AppsChanged != 0 || o.Blind != 0 {
		t.Fatalf("only the save's own writes moved, but the walk counted a change: %+v", o)
	}
	if o.SelfSkipped != 3 {
		t.Fatalf("selfSkipped = %d, want 3", o.SelfSkipped)
	}
	// nowhere-claims alone: the vault push writes it at every seal, even when empty.
	tr.scwAgeAll(t)
	tr.scwNew(t, d+"/nowhere-claims", d)
	_, _, o = tr.walk(t, tr.change())
	if o.ChangedFiles != 0 || o.SelfSkipped != 1 {
		t.Fatalf("nowhere-claims alone: changedFiles=%d selfSkipped=%d, want 0 and 1", o.ChangedFiles, o.SelfSkipped)
	}
}

func TestSealChangeWalkC4ChooserChoiceCounts(t *testing.T) {
	tr := scwSetup(t)
	d := "vault/" + sealChangeSelfDir
	tr.scwAgeAll(t)
	tr.scwNew(t, d+"/nowhere-save-mode", d)
	_, _, o := tr.walk(t, tr.change())
	if o.ChangedFiles != 1 || o.ChangedDirs != 0 {
		t.Fatalf("a chooser choice written: changedFiles=%d changedDirs=%d, want 1 and 0", o.ChangedFiles, o.ChangedDirs)
	}
}

func TestSealChangeWalkC5StateFile(t *testing.T) {
	tr := scwSetup(t)
	tr.scwAgeAll(t)
	tr.scwNew(t, "state/settings_secure.xml")
	_, _, o := tr.walk(t, tr.change())
	if o.StateChanged != 1 || o.Blind != 0 {
		t.Fatalf("a settings file touched: stateChanged=%d blind=%d, want 1 and 0", o.StateChanged, o.Blind)
	}
	os.RemoveAll(tr.state)
	_, _, o = tr.walk(t, tr.change())
	if o.StateChanged != 0 || o.Blind != 0 {
		t.Fatalf("absent state files: stateChanged=%d blind=%d, want 0 and 0", o.StateChanged, o.Blind)
	}
}

func TestSealChangeWalkC6AppDirChild(t *testing.T) {
	tr := scwSetup(t)
	if err := os.MkdirAll(filepath.Join(tr.appDir, "~~new=="), 0o755); err != nil {
		t.Fatal(err)
	}
	tr.scwAgeAll(t)
	tr.scwNew(t, "app/~~new==")
	_, _, o := tr.walk(t, tr.change())
	if o.AppsChanged != 1 || o.Blind != 0 {
		t.Fatalf("an app installed: appsChanged=%d blind=%d, want 1 and 0", o.AppsChanged, o.Blind)
	}
}

func TestSealChangeWalkC7UnreadableDir(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 0000 dir; the blind arm needs a non-root run")
	}
	tr := scwSetup(t)
	tr.scwAgeAll(t)
	p := filepath.Join(tr.roots["vault"], "com.example.scw")
	if err := os.Chmod(p, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(p, 0o755) })
	_, _, o := tr.walk(t, tr.change())
	if o.Blind == 0 {
		t.Fatalf("an unreadable dir: blind=0, want > 0: %+v", o)
	}
}

func TestSealChangeWalkC8PlainModeUnchanged(t *testing.T) {
	tr := scwSetup(t)
	d := "vault/" + sealChangeSelfDir
	for _, f := range []string{"nowhere-claims", "bt-bond-bt_config"} {
		scwWrite(t, filepath.Join(tr.base, d, f))
	}
	tr.scwAgeAll(t)
	tr.scwNew(t, d+"/nowhere-nav", d+"/nowhere-claims", d+"/bt-bond-bt_config", d, "state/settings_secure.xml")
	sinceArg := strconv.FormatInt(tr.since, 10)
	b, m, o := tr.walk(t, sinceArg)
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"blind", "changedBytes", "changedFiles", "deferredChangedBytes", "deferredChangedFiles", "deletedBytes", "deletedFiles", "since", "v"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("plain mode keys = %v, want exactly %v", keys, want)
	}
	exp, _ := json.Marshal(sealDeltaWalk(tr.roots, map[string]string{}, map[string]sealDeltaIdxEnt{}, nil, tr.since))
	if string(b) != string(exp) {
		t.Fatalf("plain mode JSON = %s, want today's %s", b, exp)
	}
	if o.ChangedFiles != 3 {
		t.Fatalf("plain mode changedFiles = %d, want 3 (the save's own writes count there, as before)", o.ChangedFiles)
	}
}

func TestSealChangeWalkC9PlainSelectors(t *testing.T) {
	tr := scwSetup(t)
	tr.scwAgeAll(t)
	for _, arg := range []string{"0 change", "5", "5 other", " 5  change extra", "-5 change", "x change", ""} {
		if _, m, _ := tr.walk(t, arg); m["mode"] != nil {
			t.Errorf("%q selected change mode; want plain", arg)
		}
	}
	for _, arg := range []string{"5 change", " 5\tchange "} {
		if _, m, _ := tr.walk(t, arg); m["mode"] != "change" {
			t.Errorf("%q: mode = %v, want change", arg, m["mode"])
		}
	}
}

// scwShellBodies maps each function nowhere_roamd.sh defines to its body, comment lines dropped.
func scwShellBodies(lines []string) map[string]string {
	def := regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)\(\) \{`)
	bodies := map[string]string{}
	for i := 0; i < len(lines); i++ {
		m := def.FindStringSubmatch(lines[i])
		if m == nil {
			continue
		}
		var b strings.Builder
		for j := i + 1; j < len(lines) && lines[j] != "}"; j++ {
			if !strings.HasPrefix(strings.TrimSpace(lines[j]), "#") {
				b.WriteString(lines[j] + "\n")
			}
		}
		bodies[m[1]] = b.String()
	}
	return bodies
}

func TestSealChangeWalkP1SelfWrittenHaveWriters(t *testing.T) {
	raw, err := os.ReadFile("../vendor-common/bin/nowhere_roamd.sh")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(raw), "\n")
	bodies := scwShellBodies(lines)
	start := -1
	for i, l := range lines {
		if l == "  out)" {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatal("no `  out)` arm in nowhere_roamd.sh")
	}
	var pre, arm strings.Builder // pre: the out arm up to its first push; arm: the whole arm
	armEnd := regexp.MustCompile(`^  [a-z][a-z0-9_-]*\)$`)
	inPre := true
	for _, l := range lines[start+1:] {
		if armEnd.MatchString(l) {
			break
		}
		if strings.HasPrefix(strings.TrimSpace(l), "#") {
			continue
		}
		if strings.Contains(l, `_push vault "$name"`) && !strings.Contains(l, "()") {
			inPre = false
		}
		if inPre {
			pre.WriteString(l + "\n")
		}
		arm.WriteString(l + "\n")
	}
	// The functions the out arm calls before its pushes, and every function those call.
	word := regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)
	called := map[string]bool{}
	queue := []string{pre.String()}
	for len(queue) > 0 {
		src := queue[0]
		queue = queue[1:]
		for _, w := range word.FindAllString(src, -1) {
			if b, ok := bodies[w]; ok && !called[w] {
				called[w] = true
				queue = append(queue, b)
			}
		}
	}
	argWriter := map[string]bool{} // a function that writes one of its arguments (`> "$4"`)
	for f := range called {
		if regexp.MustCompile(`> "\$[1-9]"`).MatchString(bodies[f]) {
			argWriter[f] = true
		}
	}
	// written reports whether body writes ref: the target of >, the last operand of mv -f or cp -f, or an
	// argument of a function that writes an argument.
	written := func(body, ref string) bool {
		q := regexp.QuoteMeta(`"` + ref + `"`)
		if regexp.MustCompile(`(>|mv -f "[^"]*"|cp -f "[^"]*") ` + q + `($|[\s;)&|])`).MatchString(body) {
			return true
		}
		for f := range argWriter {
			if regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(f) + `\s.*` + q).MatchString(body) {
				return true
			}
		}
		return false
	}
	assign := regexp.MustCompile(`(?:^|[\s;])(?:local )?([A-Za-z_][A-Za-z0-9_]*)="\$_bd/([^"$]+)"`)
	hasWriter := func(name string, prefix bool) bool {
		for f := range called {
			body := bodies[f]
			if prefix {
				m := regexp.MustCompile(`(?:local )?([A-Za-z_][A-Za-z0-9_]*)="\$_bd/` + regexp.QuoteMeta(name)).FindStringSubmatch(body)
				if m != nil && (written(body, "$"+m[1]) || written(body, "$"+m[1]+".tmp")) {
					return true
				}
				continue
			}
			if written(body, "$_bd/"+name) {
				return true
			}
			for _, m := range assign.FindAllStringSubmatch(body, -1) {
				v, b := m[1], m[2]
				for _, sfx := range []string{"", ".tmp", ".raw"} {
					if name == b+sfx && written(body, "$"+v+sfx) {
						return true
					}
				}
			}
		}
		// The out arm's own write-backs: the claims list (the vault push writes it, then .tmp + rename) and the
		// media-scan list (the arm's sed > "$_msdst").
		armS := arm.String()
		for _, v := range []string{"CLAIMSOUT", "_msdst"} {
			for _, sfx := range []string{"", ".tmp"} {
				b := strings.TrimSuffix(name, sfx)
				if prefix || b+sfx != name || !strings.Contains(armS, v+`="$USERDIR/`+sealChangeSelfDir+"/"+b+`"`) {
					continue
				}
				switch v {
				case "_msdst":
					if sfx == "" && written(armS, "$_msdst") {
						return true
					}
				case "CLAIMSOUT":
					if strings.Contains(armS, `NOWHERE_CLAIMS_OUT="$CLAIMSOUT"`) && scwClaimsWriter(t) {
						return true
					}
				}
			}
		}
		return false
	}
	if len(called) == 0 {
		t.Fatal("found no function the out arm calls")
	}
	for _, e := range sealChangeSelfWritten {
		if !strings.HasPrefix(e, sealChangeSelfDir+"/") || !hasWriter(strings.TrimPrefix(e, sealChangeSelfDir+"/"), false) {
			t.Errorf("sealChangeSelfWritten entry %q has no writer in the out arm of nowhere_roamd.sh", e)
		}
	}
	for _, p := range sealChangeSelfWrittenPrefixes {
		if !strings.HasPrefix(p, sealChangeSelfDir+"/") || !hasWriter(strings.TrimPrefix(p, sealChangeSelfDir+"/"), true) {
			t.Errorf("sealChangeSelfWrittenPrefixes entry %q has no writer in the out arm of nowhere_roamd.sh", p)
		}
	}
}

// scwClaimsWriter reports whether the agent writes NOWHERE_CLAIMS_OUT through a .tmp and a rename.
func scwClaimsWriter(t *testing.T) bool {
	t.Helper()
	b, err := os.ReadFile("app_claim.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	return strings.Contains(s, `os.Getenv("NOWHERE_CLAIMS_OUT")`) && strings.Contains(s, "tmp := p + \".tmp\"") && strings.Contains(s, "os.Rename(tmp, p)")
}

func TestSealChangeWalkP2NoPropertyPath(t *testing.T) {
	ps := sealChangeStatePaths("10")
	if len(ps) == 0 {
		t.Fatal("the state list is empty")
	}
	for _, p := range ps {
		if strings.HasPrefix(p, "/data/property") {
			t.Errorf("state path %q is property_data_file: endospore_priv may not stat it, so every walk would be blind", p)
		}
		if !filepath.IsAbs(p) || filepath.Clean(p) != p || strings.Contains(p, "//") {
			t.Errorf("state path %q is not a clean absolute path", p)
		}
	}
}
