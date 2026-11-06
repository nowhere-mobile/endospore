package main

// NWP-20261128-41: the seal reads /proc/self/mounts, which writes a space in a mountpoint as \040, a tab as \011, a
// newline as \012 and a backslash as \134. WhatsApp names every media folder with a space ("WhatsApp Video"), so
// unescapeMountPath and parseMediaOverlayUndersPub must key each overlay by its REAL path: an overlay keyed by its
// escaped text goes UNRESOLVED, the walk skips its subtree and the manifest comes out short. The shell mirror is
// nowhere_mediad.sh's unesc_mount, tested by core/vendor-common/prebuilts/test-mount-unescape.sh; these tests are
// the Go half. test-mount-unescape-go.sh --mutate runs them against broken copies of media_seal.go.

import (
	"strings"
	"testing"
)

// encMount writes a path the way /proc/self/mounts does. The backslash goes first, so the encoder never
// re-escapes its own output. It is the test's own encoder: no fixture is built with unescapeMountPath.
func encMount(s string) string {
	s = strings.ReplaceAll(s, `\`, `\134`)
	s = strings.ReplaceAll(s, " ", `\040`)
	s = strings.ReplaceAll(s, "\t", `\011`)
	return strings.ReplaceAll(s, "\n", `\012`)
}

const (
	unescSrc      = "/data/media/11"
	unescBindRoot = "/data/user/11/com.nowhere.chooser/files/.nowhere-media-ext/.under/"
)

func unescOverlayLine(rel string) string {
	return "nowhere_media " + encMount(unescSrc+"/"+rel) + " fuse.nowheremedia rw,allow_other 0 0"
}

func unescBindLine(rel string) string {
	return "/dev/block/dm-12 " + encMount(unescBindRoot+underLeaf(rel)) + " f2fs rw 0 0"
}

func assertNoBackslash(t *testing.T, got map[string]string) {
	t.Helper()
	for k, v := range got {
		if strings.Contains(k, `\`) || strings.Contains(v, `\`) {
			t.Errorf("an escape survived the parse: %q -> %q", k, v)
		}
	}
}

func TestUnescapeMountPath(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"space", `a\040b`, "a b"},
		{"tab", `a\011b`, "a\tb"},
		{"newline", `a\012b`, "a\nb"},
		{"backslash", `a\134b`, `a\b`},
		{"single pass", `x\134040`, `x\040`},
		{"escape at the end", `dir\040`, "dir "},
		{"lone trailing backslash", `a\`, `a\`},
		{"short trailing escape", `a\04`, `a\04`},
		{"unknown escape", `a\101`, `a\101`},
		{"no backslash", "/data/media/11/Pictures", "/data/media/11/Pictures"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := unescapeMountPath(c.in)
			if got != c.want {
				t.Errorf("unescapeMountPath(%q) = %q, want %q", c.in, got, c.want)
			}
			if c.name == "single pass" && got == "x " {
				t.Errorf("unescapeMountPath(%q) decoded twice: %q", c.in, got)
			}
		})
	}
}

func TestParseUndersSpaceFolderResolvesThroughTheBind(t *testing.T) {
	rel := "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video"
	fixture := unescOverlayLine(rel) + "\n" + unescBindLine(rel) + "\n"
	if !strings.Contains(fixture, `WhatsApp\040Video`) {
		t.Fatalf("the fixture holds no escaped space:\n%s", fixture)
	}
	got, err := parseMediaOverlayUndersPub(strings.NewReader(fixture), unescSrc, nil)
	if err != nil {
		t.Fatalf("parseMediaOverlayUndersPub: %v", err)
	}
	overlay, want := unescSrc+"/"+rel, unescBindRoot+underLeaf(rel)
	if len(got) != 1 || got[overlay] != want {
		t.Errorf("got %q, want exactly {%q: %q}", got, overlay, want)
	}
	assertNoBackslash(t, got)
}

func TestParseUndersSpaceFolderResolvesThroughThePublishedMap(t *testing.T) {
	rel := "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video"
	fixture := unescOverlayLine(rel) + "\n"
	overlay := unescSrc + "/" + rel
	pubUnder := "/data/user/11/com.nowhere.chooser/files/.nowhere-media-ext/published/WhatsApp Video"
	got, err := parseMediaOverlayUndersPub(strings.NewReader(fixture), unescSrc, map[string]string{overlay: pubUnder})
	if err != nil {
		t.Fatalf("parseMediaOverlayUndersPub: %v", err)
	}
	if len(got) != 1 || got[overlay] != pubUnder {
		t.Errorf("got %q, want exactly {%q: %q} from the published map", got, overlay, pubUnder)
	}
	assertNoBackslash(t, got)
}

func TestParseUndersTabAndBackslashFolders(t *testing.T) {
	relTab := "Android/media/com.example.notes/Voice\tNotes"
	relLit := `Android/media/com.example.notes/Voice\040Notes` // a real backslash in the name
	fixture := strings.Join([]string{
		unescOverlayLine(relTab), unescBindLine(relTab),
		unescOverlayLine(relLit), unescBindLine(relLit),
	}, "\n") + "\n"
	if !strings.Contains(fixture, `Voice\011Notes`) || !strings.Contains(fixture, `Voice\134040Notes`) {
		t.Fatalf("the fixture does not hold both escapes:\n%s", fixture)
	}
	got, err := parseMediaOverlayUndersPub(strings.NewReader(fixture), unescSrc, nil)
	if err != nil {
		t.Fatalf("parseMediaOverlayUndersPub: %v", err)
	}
	tabKey, litKey := unescSrc+"/"+relTab, unescSrc+"/"+relLit
	tabWant, litWant := unescBindRoot+underLeaf(relTab), unescBindRoot+underLeaf(relLit)
	if len(got) != 2 || got[tabKey] != tabWant || got[litKey] != litWant {
		t.Errorf("got %q, want exactly {%q: %q, %q: %q}", got, tabKey, tabWant, litKey, litWant)
	}
	if got[tabKey] == litWant || got[litKey] == tabWant {
		t.Errorf("the tab and the backslash folders crossed: %q", got)
	}
}
