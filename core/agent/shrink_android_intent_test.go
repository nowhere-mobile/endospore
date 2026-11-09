package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// EXPECT-SHRINK-ANDROID and the verdict on its marker (NWP-20261129-04): docs/product-decisions.md, 2026-11-05, #5. A
// clear in Android Settings armed nothing, so every later seal of a large app's scope was refused and the sign-out
// wedged. The marker speaks only for the packages Android named, by the sealed bytes they lost.

func saLogin(t *testing.T, dest, payload string) string {
	t.Helper()
	return driveLogin(t, dest, "EXPECT-SHRINK-ANDROID\n"+payload+"\n")
}

func saWant(t *testing.T, scope string, want ...string) {
	t.Helper()
	in := readShrinkIntent(profileRefV2(scope, esPass))
	if !in.armed || in.kind != "android" || !reflect.DeepEqual(in.declared, want) {
		t.Errorf("%q marker = armed %v kind %q names %v, want android %v", scope, in.armed, in.kind, in.declared, want)
	}
}

// (a) the verb, through handleLogin with a live session.
func TestShrinkAndroid_Verb(t *testing.T) {
	t.Run("arms three scopes, never apps", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		dest := esSession(t)
		if got := saLogin(t, dest, "com.example.a com.example.b bad..name com.example.a"); got != "OK" {
			t.Fatalf("reply = %q, want OK", got)
		}
		for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media"} {
			saWant(t, sc, "com.example.a", "com.example.b")
		}
		if esExists(esMarker(esProfile + "#apps")) {
			t.Error("the verb wrote a #apps marker: the logoff prune owns an uninstall's #apps drop")
		}
		if got := saLogin(t, dest, "com.example.c"); got != "OK" {
			t.Fatalf("second call reply = %q, want OK", got)
		}
		for _, sc := range []string{esProfile, esProfile + "#de", esProfile + "#media"} {
			saWant(t, sc, "com.example.a", "com.example.b", "com.example.c")
		}
	})
	t.Run("never narrows a deliberate marker", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		const body = "deliberate\ngen=0011223344556677\n"
		de := esSeed(t, esProfile+"#de", body)
		if got := saLogin(t, esSession(t), "com.example.a"); got != "OK" {
			t.Fatalf("reply = %q, want OK", got)
		}
		if got := esRead(t, de); got != body {
			t.Errorf("deliberate #de marker = %q, want it byte-identical", got)
		}
		saWant(t, esProfile, "com.example.a")
		saWant(t, esProfile+"#media", "com.example.a")
	})
	t.Run("no session and no valid name", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		if got := saLogin(t, t.TempDir(), "com.example.a"); got != "NONE" {
			t.Errorf("no session: reply = %q, want NONE", got)
		}
		if got := saLogin(t, esSession(t), "bad..name ../etc nodots"); got != "NONE" {
			t.Errorf("no valid name: reply = %q, want NONE", got)
		}
		if esExists(esMarker(esProfile)) {
			t.Error("a NONE reply wrote a marker")
		}
	})
	t.Run("a failed write answers ERR", func(t *testing.T) {
		st := t.TempDir()
		t.Setenv("NOWHERE_STATE", st)
		if err := os.WriteFile(filepath.Join(st, "shrink-intent"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		var got string
		log := esStderr(t, func() { got = saLogin(t, esSession(t), "com.example.secretapp") })
		if got != "ERR" {
			t.Errorf("reply = %q, want ERR", got)
		}
		if strings.Contains(log, "secretapp") {
			t.Errorf("the failure line names a package: %q", log)
		}
	})
	t.Run("at most 64 names", func(t *testing.T) {
		t.Setenv("NOWHERE_STATE", t.TempDir())
		var names []string
		for i := 0; i < 70; i++ {
			names = append(names, fmt.Sprintf("com.example.a%02d", i))
		}
		if got := saLogin(t, esSession(t), strings.Join(names, " ")); got != "OK" {
			t.Fatalf("reply = %q, want OK", got)
		}
		saWant(t, esProfile+"#de", names[:64]...)
	})
	t.Run("answers BUSY behind a long op", func(t *testing.T) {
		if concurrentSafeCmd("EXPECT-SHRINK-ANDROID") {
			t.Fatal("the verb WRITES state the seal reads: it must not run free")
		}
		sessionMu.Lock()
		defer sessionMu.Unlock()
		if got := replyWhileHeld(t, 5*time.Second, "EXPECT-SHRINK-ANDROID\ncom.example.a\n", "EXPECT-SHRINK-ANDROID"); got != "BUSY" {
			t.Fatalf("reply = %q, want BUSY", got)
		}
	})
}

// (b) the pure verdict: lost is 1000 unless a row says otherwise.
func TestShrinkAndroid_Explains(t *testing.T) {
	const p, q = "com.example.a", "com.example.b"
	old := func(n int64) map[string]int64 { return map[string]int64{p: n, q: 500} }
	for _, c := range []struct {
		name         string
		declared     []string
		oldPkg       map[string]int64
		newPkg       map[string]int64
		measured     bool
		drop         map[string]bool
		dropped, def int64
		lost         int64
		ok           bool
		short        int64
	}{
		{name: "the shortfall is the whole loss", declared: []string{p}, oldPkg: old(1000), measured: true, lost: 1000, ok: true, short: 1000},
		{name: "85 percent", declared: []string{p}, oldPkg: old(850), measured: true, lost: 1000, ok: true, short: 850},
		{name: "exactly four fifths", declared: []string{p}, oldPkg: old(800), measured: true, lost: 1000, ok: true, short: 800},
		{name: "75 percent", declared: []string{p}, oldPkg: old(750), measured: true, lost: 1000, short: 750},
		{name: "a name absent from the old index adds 0", declared: []string{"com.example.absent"}, oldPkg: old(1000), measured: true, lost: 1000},
		{name: "an unmeasured seal vouches for nothing", declared: []string{p}, oldPkg: old(1000), measured: false, lost: 1000, short: 1000},
		{name: "an index-less head vouches for nothing", declared: []string{p}, oldPkg: map[string]int64{}, measured: true, dropped: 1000, lost: 1000},
		{name: "a drop-listed name is counted once", declared: []string{p}, oldPkg: old(1000), measured: true, drop: map[string]bool{p: true}, dropped: 1000, lost: 1000, ok: true},
		{name: "a drop-listed name is not counted twice", declared: []string{p}, oldPkg: old(1000), measured: true, drop: map[string]bool{p: true}, dropped: 1000, lost: 2000},
		{name: "a repeated name is counted once", declared: []string{p, p}, oldPkg: old(600), measured: true, lost: 1000, short: 600},
		{name: "a grown package adds 0", declared: []string{p}, oldPkg: old(100), newPkg: map[string]int64{p: 900}, measured: true, lost: 1000},
		{name: "a partial clear counts what it lost", declared: []string{p}, oldPkg: old(1000), newPkg: map[string]int64{p: 100}, measured: true, lost: 900, ok: true, short: 900},
		{name: "the walk's bytes sit beside the declared ones", declared: []string{p}, oldPkg: old(500), measured: true, dropped: 200, def: 200, lost: 1000, ok: true, short: 500},
		{name: "nothing explained on a count-only collapse", declared: []string{"com.example.absent"}, oldPkg: old(10), measured: true, lost: -5},
	} {
		ok, short := shrinkAndroidExplains(c.declared, c.oldPkg, c.newPkg, c.measured, c.drop, c.dropped, c.def, c.lost)
		if ok != c.ok || short != c.short {
			t.Errorf("%s: got (%v, %d), want (%v, %d)", c.name, ok, short, c.ok, c.short)
		}
	}
	if ok, _ := shrinkIntentAllowed("android", []string{p}, old(1), nil, nil); ok {
		t.Error("shrinkIntentAllowed allowed an android marker outright")
	}
}

// saFixture seals a #de head: com.example.biggame 8 x 3 MiB, com.example.other 1.2 MiB, one small prefs file and, with
// second set, com.example.second 4 x 3 MiB.
func saFixture(t *testing.T, name string, second bool) *handset {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	a, _ := twoWriters(t, name, "correct horse battery staple")
	for _, n := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		a.put("com.example.biggame/files/"+n+".bin", detailBlob("biggame"+n, 3<<20))
	}
	if second {
		for _, n := range []string{"a", "b", "c", "d"} {
			a.put("com.example.second/files/"+n+".bin", detailBlob("second"+n, 3<<20))
		}
	}
	a.put("com.example.other/files/keep.bin", detailBlob("other", 1200<<10))
	a.put("com.example.small/shared_prefs/p.xml", "<map/>")
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	return a
}

func saRemove(t *testing.T, a *handset, pkgs ...string) {
	t.Helper()
	for _, p := range pkgs {
		if err := os.RemoveAll(filepath.Join(a.work, p)); err != nil {
			t.Fatal(err)
		}
	}
}

// saSeal seals #de and returns why it did not land and its output. The two new lines never name a package.
func saSeal(t *testing.T, a *handset) (string, string) {
	t.Helper()
	var msg string
	out := captureStdout(t, func() { msg = a.seal("#de") })
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, "(NWP-20261129-04)") && strings.Contains(ln, "com.example.") {
			t.Errorf("a new log line names a package: %q", ln)
		}
	}
	return msg, out
}

// saMark arms the android marker the way the verb does, inside the handset's own state dir.
func saMark(t *testing.T, a *handset, pkgs ...string) (token string) {
	t.Helper()
	a.as(func() {
		if err := markProfileShrinkAndroid(a.name, a.pass, pkgs); err != nil {
			t.Fatal(err)
		}
		in := readShrinkIntent(profileRefV2(a.name+"#de", a.pass))
		if !in.armed || in.kind != "android" {
			t.Fatalf("the marker did not arm: %+v", in)
		}
		token = in.token
	})
	return token
}

func saMarker(a *handset) (in shrinkIntent) {
	a.as(func() { in = readShrinkIntent(profileRefV2(a.name+"#de", a.pass)) })
	return in
}

const saAllowedLine = "Android cleared or removed account for"

// (c) the clear of a large app: refused unarmed (so the net really fires here), allowed armed, the marker retired.
func TestShrinkAndroid_SealAllowsNamedPackage(t *testing.T) {
	a := saFixture(t, "saallow", false)
	before := headManifestOf(t, a.base, a.name+"#de", a.pass)
	headRef := a.head("#de")
	saRemove(t, a, "com.example.biggame")
	if msg, out := saSeal(t, a); msg == "" {
		t.Fatalf("control: the unarmed seal landed, so the net does not fire on this fixture:\n%s", out)
	}
	saMark(t, a, "com.example.biggame")
	msg, out := saSeal(t, a)
	if msg != "" {
		t.Fatalf("the armed seal did not land: %s\n%s", msg, out)
	}
	if !strings.Contains(out, saAllowedLine) {
		t.Errorf("the seal landed without the android ALLOWED line:\n%s", out)
	}
	if strings.Contains(out, "the user deliberately cleared storage") {
		t.Errorf("the deliberate line printed for an android marker:\n%s", out)
	}
	if a.head("#de") == headRef {
		t.Error("the head did not move")
	}
	after := headManifestOf(t, a.base, a.name+"#de", a.pass)
	if len(after.Chunks)*5 >= len(before.Chunks) || after.Pkg["com.example.biggame"] != 0 {
		t.Errorf("the head is not the shrunken one: %d -> %d chunks, Pkg=%v", len(before.Chunks), len(after.Chunks), after.Pkg)
	}
	if in := saMarker(a); in.armed {
		t.Errorf("the seal that used the marker left it armed: %+v", in)
	}
}

// (d) an undeclared loss over a quarter of the declared one: refused, the head and the marker unchanged. A deliberate
// marker then still allows the same shrink outright, with its own line.
func TestShrinkAndroid_SealRefusesUndeclaredLoss(t *testing.T) {
	a := saFixture(t, "sarefuse", true)
	headRef := a.head("#de")
	saRemove(t, a, "com.example.biggame", "com.example.second")
	token := saMark(t, a, "com.example.biggame")
	msg, out := saSeal(t, a)
	if msg == "" {
		t.Fatalf("a marker naming one package excused another's loss:\n%s", out)
	}
	if !strings.Contains(out, "refusing as if unarmed (NWP-20261129-04)") || !strings.Contains(out, "SEAL REFUSED") {
		t.Errorf("the refusal did not print the marker's line and the refusal arm's:\n%s", out)
	}
	if a.head("#de") != headRef {
		t.Error("a refused seal moved the head")
	}
	if in := saMarker(a); !in.armed || in.token != token {
		t.Errorf("a refused seal touched the marker: %+v, want token %q", in, token)
	}
	a.as(func() {
		if err := markProfileShrinkIntent(a.name, a.pass); err != nil {
			t.Fatal(err)
		}
	})
	msg, out = saSeal(t, a)
	if msg != "" || !strings.Contains(out, "ALLOWED -- the user deliberately cleared storage for this scope") {
		t.Errorf("a deliberate marker no longer allows outright: %q\n%s", msg, out)
	}
}

// (e) no file >= 1 MiB left, every removed package named: the marker case precedes the len(seen)==0 arm.
func TestShrinkAndroid_SealAllowsWhenNoLargeFileIsLeft(t *testing.T) {
	a := saFixture(t, "sanolarge", false)
	saRemove(t, a, "com.example.biggame", "com.example.other")
	msg, out := saSeal(t, a)
	if msg == "" || !strings.Contains(out, "NONE >=") {
		t.Fatalf("control: the unarmed seal did not reach the len(seen)==0 arm: %q\n%s", msg, out)
	}
	saMark(t, a, "com.example.biggame", "com.example.other")
	msg, out = saSeal(t, a)
	if msg != "" {
		t.Fatalf("the armed seal did not land: %s\n%s", msg, out)
	}
	if !strings.Contains(out, saAllowedLine) {
		t.Errorf("the seal landed without the android ALLOWED line:\n%s", out)
	}
	if in := saMarker(a); in.armed {
		t.Errorf("the seal that used the marker left it armed: %+v", in)
	}
}

// The #apps presence guard: no writer arms android on #apps, so this is a defence: a hand-seeded marker speaks only for
// the packages it names and never as the user's whole-scope word.
func TestShrinkAndroid_AppsGuardNamedOnly(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "saapps", "correct horse battery staple"
	createVault(base, name, pass)
	arm := func() {
		t.Helper()
		f := shrinkIntentFile(profileRefV2(name+"#apps", pass))
		if err := commitShrinkMarkers([]shrinkTarget{{f, withGen("android\ncom.example.named\n")}}); err != nil {
			t.Fatal(err)
		}
	}
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.named", "com.example.unnamed")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	arm()
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.unnamed")); refused {
		t.Fatal("an android marker did not excuse the package it named")
	}
	arm()
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.keep")); !refused {
		t.Fatal("an android marker naming one package excused a different one")
	}
}
