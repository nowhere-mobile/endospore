package main

// NWP-20261026-08: a sign-in that found NO #media head records an empty login roster, so the session's seals run the
// essential carry against an empty restored set instead of skipping it for want of a roster. Two handsets, one
// account: the first signs in to a profile with no #media head, the second to the head the first one created.

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

const noHeadPass = "correct horse battery staple"

// signInNoHead is handset h signing in to a #media scope the store holds no head for.
func signInNoHead(h *handset) (noted bool) {
	h.t.Helper()
	h.as(func() { noted = noteNoMediaHeadAtLogin(h.base, h.name+"#media", h.pass) })
	return noted
}

func TestMediaCarryNoHead_ASecondHandsetsNewFileSurvivesTheFirstOnesSeals(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "nohead-two", noHeadPass)
	ref := profileRefV2("nohead-two#media", noHeadPass)

	if !signInNoHead(a) {
		t.Fatal("a sign-in to a scope with no head recorded no roster")
	}
	a.put("DCIM/a.jpg", "the first photo")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's first seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.as(func() { loginArrived(ref, atLogin) })
	b.put("DCIM/a.jpg", "the first photo") // what B's restore materialised
	b.put("DCIM/from-b.jpg", "a small screenshot")
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("A's second seal: %s", msg)
		}
	})
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Ess["DCIM/from-b.jpg"]; !ok {
		t.Fatalf("A's seal DROPPED B's screenshot (head indexes %v). Output:\n%s", keysOfEss(m.Ess), out)
	}
	if !strings.Contains(out, "carry: the head indexes") {
		t.Errorf("A's seal did not run the carry. Output:\n%s", out)
	}
}

func TestMediaCarryNoHead_ADeletionOnTheFirstHandsetStillWins(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "nohead-del", noHeadPass)

	if !signInNoHead(a) {
		t.Fatal("a sign-in to a scope with no head recorded no roster")
	}
	a.put("DCIM/keep.jpg", "kept")
	a.put("DCIM/a-tmp.jpg", "temporary")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("first seal: %s", msg)
	}
	a.rm("DCIM/a-tmp.jpg")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("seal after the delete: %s", msg)
	}
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Ess["DCIM/a-tmp.jpg"]; ok {
		t.Fatalf("the deleted file came back (head indexes %v)", keysOfEss(m.Ess))
	}
	if _, ok := m.Ess["DCIM/keep.jpg"]; !ok {
		t.Fatalf("the kept file is missing (head indexes %v)", keysOfEss(m.Ess))
	}
}

func TestMediaCarryNoHead_AFailedProbeWritesNoSentinel(t *testing.T) {
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	a, b := twoWriters(t, "nohead-probe", noHeadPass)
	ref := profileRefV2("nohead-probe#media", noHeadPass)

	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer broken.Close()
	var noted bool
	a.as(func() { noted = noteNoMediaHeadAtLogin(broken.URL, "nohead-probe#media", noHeadPass) })
	if noted {
		t.Fatal("a probe that failed was taken for an absent head")
	}
	a.as(func() {
		if f := loginRosterFile(ref); f != "" {
			if _, err := os.Stat(f); err == nil {
				t.Fatalf("a roster file exists after a failed probe: %s", f)
			}
		}
	})

	// B creates the head; A holds a receipt but no roster, so its seal must still skip the carry.
	b.put("DCIM/b.jpg", "from b")
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	head := b.head("#media")
	a.as(func() { writeRestoreReceipt(ref, head) })
	a.put("DCIM/a.jpg", "from a")
	out := captureStdout(t, func() { a.seal("#media") })
	if !strings.Contains(out, "no restore receipt") {
		t.Errorf("a session whose probe failed did not skip the carry for want of a roster. Output:\n%s", out)
	}
}

func TestMediaCarryNoHead_OtherScopesRecordNothing(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "nohead-scope", noHeadPass)
	for _, scope := range []string{"", "#apps"} {
		var noted bool
		a.as(func() { noted = noteNoMediaHeadAtLogin(a.base, "nohead-scope"+scope, noHeadPass) })
		if noted {
			t.Errorf("scope %q recorded a no-head roster", scope)
		}
		ref := profileRefV2("nohead-scope"+scope, noHeadPass)
		a.as(func() {
			if f := loginRosterFile(ref); f != "" {
				if _, err := os.Stat(f); err == nil {
					t.Errorf("scope %q wrote a roster file", scope)
				}
			}
		})
	}
}

// The restore verb's `empty -> nothing` arm must call the note before it prints and returns.
func TestMediaCarryNoHead_TheRestoreVerbNotesItsEmptyArm(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatal(err)
	}
	at := strings.Index(src, `"restore: profile %s empty -> nothing [%s]\n"`)
	if at < 0 {
		t.Fatal("the restore verb's empty-nothing line is gone")
	}
	arm := src[strings.LastIndex(src[:at], "if !ok {"):at]
	if !strings.Contains(arm, "noteNoMediaHeadAtLogin(") {
		t.Fatal("the restore verb's `empty -> nothing` arm does not call noteNoMediaHeadAtLogin before it prints")
	}
}
