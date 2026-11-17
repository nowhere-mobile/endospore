package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261204-01 (h58 #1, docs/product-decisions.md, 2026-11-04, "two answers to harvest 58"): a seal round that
// leaves a scope unsaved records its parts in the bare vault's scope index (!round), the next bare seal that lands
// clears it, and a bare restore says so and leaves the parts for the login daemon. These tests pin the record's
// shape, the writer, the clear, the receipt, the restore's read and the daemon's read. Every test has its own
// profile name, and rrStore resets the DK-keyed caches.

// rrStore stands up a fresh store and resets the DK-keyed caches.
func rrStore(t *testing.T) string {
	t.Helper()
	base := newHTTPStore(t)
	blobCache = nil
	contentCache = nil
	return base
}

// rrProfile creates (name, pass) and makes one bare seal of it.
func rrProfile(t *testing.T, base, name, pass string) {
	t.Helper()
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	rrSeal(t, base, name, pass)
}

// rrSeal makes one seal of (name, pass); name may carry a #scope.
func rrSeal(t *testing.T, base, name, pass string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte("payload "+name), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d)
}

// rrVault opens (name, pass)'s bare vault and its index.
func rrVault(t *testing.T, base, name, pass string) (*vault, map[string]scopeRec, []byte, string) {
	t.Helper()
	dk, _, ok := resolveKey(base, name, pass)
	if !ok {
		t.Fatalf("%q does not resolve", name)
	}
	head := getRef(base, headKey(base, name, pass))
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		t.Fatalf("%q: the head is not a vault", name)
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatalf("%q: the vault carries no scope index", name)
	}
	return v, idx, dk, head
}

// (a) the record's shape.
func TestRoundRecordRecShapeRoundTrips(t *testing.T) {
	idx := map[string]scopeRec{scopeRoundKey: roundRec(1700000000, "de=unreachable,apps=failed")}
	ts, parts, ok := roundOf(idx)
	if !ok || ts != 1700000000 || parts != "de=unreachable,apps=failed" {
		t.Fatalf("roundOf(roundRec(...)) = %d %q %v", ts, parts, ok)
	}
	if idx[scopeRoundKey].Wrapped != "" || !strings.HasPrefix(idx[scopeRoundKey].Ref, billRefPrefix+"r1:") {
		t.Fatalf("the record is not in the unresolvable p2:r1: shape: %+v", idx[scopeRoundKey])
	}
	hx := func(s string) string { return roundRec(0, s).Ref[len(billRefPrefix+"r1:0:"):] }
	bad := map[string]string{
		"no p2: prefix":    "r1:1:" + hx("de=failed"),
		"no r1: version":   billRefPrefix + "r2:1:" + hx("de=failed"),
		"bad hex":          billRefPrefix + "r1:1:zz",
		"no time":          billRefPrefix + "r1::" + hx("de=failed"),
		"a non-digit time": billRefPrefix + "r1:1x:" + hx("de=failed"),
		"no hex field":     billRefPrefix + "r1:1",
		"an unknown scope": billRefPrefix + "r1:1:" + hx("keys=failed"),
		"a repeated scope": billRefPrefix + "r1:1:" + hx("de=failed,de=timeout"),
		"an empty list":    billRefPrefix + "r1:1:",
		"six items":        billRefPrefix + "r1:1:" + hx("vault=failed,de=failed,media=failed,sys=failed,apps=failed,de=x"),
		"an upper cause":   billRefPrefix + "r1:1:" + hx("de=Failed"),
		"a long cause":     billRefPrefix + "r1:1:" + hx("de=a"+strings.Repeat("b", 32)),
		"no cause":         billRefPrefix + "r1:1:" + hx("de="),
		"an empty item":    billRefPrefix + "r1:1:" + hx("de=failed,"),
	}
	for why, ref := range bad {
		if _, p, ok := roundOf(map[string]scopeRec{scopeRoundKey: {Ref: ref}}); ok {
			t.Errorf("roundOf accepted %s (%q -> %q)", why, ref, p)
		}
	}
	if _, _, ok := roundOf(map[string]scopeRec{}); ok {
		t.Error("roundOf found a record in an empty index")
	}
	if _, _, ok := roundOf(map[string]scopeRec{scopeRoundKey: roundRec(5, "vault=failed,de=unreachable,media=timeout,sys=refused,apps=nocredit")}); !ok {
		t.Error("roundOf refused a record naming all five scopes once")
	}
	if isScopeSuffix(scopeRoundKey) {
		t.Error(`isScopeSuffix("!round") is true: every walker would treat the round record as a scope`)
	}
}

// (b) the writer records the real parts only and changes nothing else.
func TestRoundRecordWritesTheRealPartsOnly(t *testing.T) {
	base := rrStore(t)
	const name, pass = "rrwrite", "round record pass one"
	rrProfile(t, base, name, pass)
	before, _, _, _ := rrVault(t, base, name, pass)
	if err := roundRecord(base, name, pass, "de=unreachable,sys=pending-placement"); err != nil {
		t.Fatalf("roundRecord: %v", err)
	}
	after, idx, _, _ := rrVault(t, base, name, pass)
	if _, parts, ok := roundOf(idx); !ok || parts != "de=unreachable" {
		t.Fatalf("the index records %q (ok=%v), want de=unreachable only", parts, ok)
	}
	if after.Manifest != before.Manifest || after.Version != before.Version || len(after.History) != len(before.History) {
		t.Fatalf("the record write changed the vault: manifest %v, version %d -> %d, history %d -> %d",
			after.Manifest != before.Manifest, before.Version, after.Version, len(before.History), len(after.History))
	}
	if err := roundRecord(base, name+"#de", pass, "de=failed"); err == nil {
		t.Error("roundRecord accepted a scope name")
	}
}

// (c) a benign part alone writes nothing.
func TestRoundRecordBenignOnlyWritesNothing(t *testing.T) {
	base := rrStore(t)
	const name, pass = "rrbenign", "round record pass two"
	rrProfile(t, base, name, pass)
	ref := headKey(base, name, pass)
	h0 := getRef(base, ref)
	if err := roundRecord(base, name, pass, "sys=pending-placement"); err != nil {
		t.Fatalf("roundRecord with a benign part only returned %v, want nil (nothing to write)", err)
	}
	if h1 := getRef(base, ref); h1 != h0 {
		t.Fatalf("a benign part alone moved the head %s -> %s", short(h0), short(h1))
	}
	if _, idx, _, _ := rrVault(t, base, name, pass); idx[scopeRoundKey].Ref != "" {
		t.Fatal("a benign part alone left a round record")
	}
}

// (d) a landed bare seal clears the record; a scope seal does not.
func TestRoundRecordClearedByABareSealNotByAScopeSeal(t *testing.T) {
	base := rrStore(t)
	const name, pass = "rrclear", "round record pass three"
	rrProfile(t, base, name, pass)
	if err := roundRecord(base, name, pass, "apps=failed"); err != nil {
		t.Fatalf("roundRecord: %v", err)
	}
	rrSeal(t, base, name+"#de", pass)
	if _, idx, _, _ := rrVault(t, base, name, pass); idx[scopeRoundKey].Ref == "" {
		t.Fatal("a #de seal cleared the round record; only a landed bare seal starts a new round")
	}
	rrSeal(t, base, name, pass)
	if _, idx, _, _ := rrVault(t, base, name, pass); idx[scopeRoundKey].Ref != "" {
		t.Fatal("a landed bare seal left the last round's record in the index")
	}
}

// (e) the record write re-anchors the receipt, so the guarded bare seal after it is not refused.
func TestRoundRecordKeepsTheReceiptAnchored(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	base := rrStore(t)
	const name, pass = "rrreceipt", "round record pass four"
	rrProfile(t, base, name, pass)
	// The restore mints the receipt; a record write never mints one.
	writeRestoreReceipt(profileRefV2(name, pass), getRef(base, headKey(base, name, pass)))
	if err := roundRecord(base, name, pass, "media=timeout"); err != nil {
		t.Fatalf("roundRecord: %v", err)
	}
	h0 := getRef(base, headKey(base, name, pass))
	refused := ""
	func() {
		defer func() {
			if r := recover(); r != nil {
				refused = "panic"
			}
		}()
		sealRefused, sealStaleHit, sealFenceHit = false, false, false
		rrSeal(t, base, name, pass)
		switch {
		case sealRefused:
			refused = "refused by a seal guard"
		case sealStaleHit:
			refused = "refused: stale publish"
		case sealFenceHit:
			refused = "refused: delete fence"
		}
	}()
	if refused != "" {
		t.Fatalf("the bare seal after a round record was %s: the record write did not re-anchor the receipt", refused)
	}
	if getRef(base, headKey(base, name, pass)) == h0 {
		t.Fatal("the bare seal after a round record did not move the head")
	}
	if _, idx, _, _ := rrVault(t, base, name, pass); idx[scopeRoundKey].Ref != "" {
		t.Fatal("the bare seal after a round record left it in the index")
	}
}

// (f) a bare restore of a recorded profile says so and writes the note; a clean profile writes nothing.
func TestRoundRecordRestoreSaysSo(t *testing.T) {
	base := rrStore(t)
	const name, pass = "rrrestore", "round record pass five"
	rrProfile(t, base, name, pass)
	out := filepath.Join(t.TempDir(), "lastsave.10")
	t.Setenv("NOWHERE_LASTSAVE_OUT", out)

	_, _, dk, head := rrVault(t, base, name, pass)
	if log := captureStdout(t, func() { noteLastRound(base, name, dk, head) }); strings.Contains(log, "did not finish") {
		t.Fatalf("a clean profile's restore said the last save did not finish: %q", log)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("a clean profile's restore wrote the last-save note (stat: %v)", err)
	}

	if err := roundRecord(base, name, pass, "de=unreachable"); err != nil {
		t.Fatalf("roundRecord: %v", err)
	}
	_, _, dk, head = rrVault(t, base, name, pass)
	log := captureStdout(t, func() { noteLastRound(base, name, dk, head) })
	if !strings.Contains(log, "-- the last save did not finish: de=unreachable unsaved (h58 #1)") {
		t.Fatalf("the restore line is missing: %q", log)
	}
	if !strings.Contains(log, "restore: profile "+logProfile(name)+" -- ") {
		t.Fatalf("the restore line does not print the profile through logProfile: %q", log)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the last-save note was not written: %v", err)
	}
	if !regexp.MustCompile(`^v=1 unsaved=de=unreachable t=[0-9]+\n$`).Match(b) {
		t.Fatalf("the last-save note is %q", b)
	}
	if st, _ := os.Stat(out); st.Mode().Perm() != 0o600 {
		t.Fatalf("the last-save note has mode %v, want 0600", st.Mode().Perm())
	}
	if got := lastSaveLine(filepath.Dir(out), "10"); got != "de=unreachable" {
		t.Fatalf("the daemon reads %q back from the restore's note", got)
	}

	// The restore verb's bare arm runs it, after the head resolved.
	body := fileFuncBody(t, "main.go", "main")
	i := strings.Index(body, `case "restore":`)
	j := strings.Index(body, "noteLastRound(base, profile, key, restoredHead)")
	k := strings.Index(body, "relGenAtRestore(base, profile, pass, restoredHead)")
	if i < 0 || j < i || k < i || j < k || strings.Count(body, "noteLastRound(") != 1 {
		t.Fatal("the restore verb's bare arm does not call noteLastRound(base, profile, key, restoredHead) once, beside relGenAtRestore")
	}
}

// (g) the login daemon's read of the note.
func TestLastSaveLine(t *testing.T) {
	d := t.TempDir()
	put := func(uid, s string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(d, "lastsave."+uid), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	put("10", "v=1 unsaved=de=unreachable,apps=failed t=1700000000\n")
	if got := lastSaveLine(d, "10"); got != "de=unreachable,apps=failed" {
		t.Fatalf("a good note reads %q", got)
	}
	if got := lastSaveLine(d, "11"); got != "" {
		t.Fatalf("a missing note reads %q", got)
	}
	bad := map[string]string{
		"oversized":      "v=1 unsaved=de=failed t=1" + strings.Repeat("0", 300) + "\n",
		"v=2":            "v=2 unsaved=de=failed t=1\n",
		"no t=":          "v=1 unsaved=de=failed\n",
		"no newline":     "v=1 unsaved=de=failed t=1",
		"an extra line":  "v=1 unsaved=de=failed t=1\nv=1 unsaved=de=failed t=1\n",
		"bad parts":      "v=1 unsaved=keys=failed t=1\n",
		"a non-digit t":  "v=1 unsaved=de=failed t=1a\n",
		"two spaces":     "v=1  unsaved=de=failed t=1\n",
		"a carriage ret": "v=1 unsaved=de=failed t=1\r\n",
	}
	for why, s := range bad {
		put("12", s)
		if got := lastSaveLine(d, "12"); got != "" {
			t.Errorf("a note with %s reads %q", why, got)
		}
	}
	put("13", "v=1 unsaved=de=failed t=1\n")
	for _, uid := range []string{"", "../13", "1a", "13/"} {
		if got := lastSaveLine(d, uid); got != "" {
			t.Errorf("uid %q reads %q", uid, got)
		}
	}
}

// (g) the sign-in's OK arm logs it to login.log, after the departed session's signals are reset.
func TestLastSaveLoggedAtSignIn(t *testing.T) {
	body := fileFuncBody(t, "main.go", "handleRoamIn")
	reset := strings.Index(body, "resetSealSignals()")
	call := strings.Index(body, "if parts := lastSaveLine(loginStateDir(), uid); parts != \"\" {")
	line := strings.Index(body, `fmt.Fprintf(os.Stderr, "[logind] sign-in: the last save of this profile did not finish: %s unsaved (h58 #1)\n", parts)`)
	if reset < 0 || call < reset || line < call || strings.Count(body, "lastSaveLine(") != 1 {
		t.Fatal("handleRoamIn's OK arm does not log the last-save note to login.log after resetSealSignals()")
	}
}
