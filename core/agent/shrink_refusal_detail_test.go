package main

// NWP-20261010-06: A SHRINK REFUSAL SAYS WHAT IT KNOWS.
//
// The len(seen)==0 arm printed entries/files/bytes and stopped. It withheld sealDropped, defMigrated and lost --
// the comparison that is the reason control reached it -- and the stored head's Pkg index, which names every
// package the head carries and its bytes. On NW-cebeb51558fd that cost nine theories; on NW-db441ee766cb
// (stallion, 2026-10-10) every #de seal was refused the same way and again named nothing:
//
//	#de SEAL REFUSED -- walked 933 entries/218 files/3160652B but NONE >=1048576B (0 via .under), so the
//	2-chunk manifest cannot account for a stored head of 124 chunks ...
//
// These tests pin that every shrink-refusal arm now carries the three numbers on the refusal line and the
// package list on lines of their own, that both survive the issue reporter's scrub (the only way a user build's
// refusal reaches anyone) -- including when a package name holds a drop keyword -- and that an older head with no
// index, a SEAL_FULL walk and a #media scope each say what they cannot show instead of printing a misleading list.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// stallionPkgs is a #de head shaped like the stallion one: 124 chunks / ~136 MB, one package holding ~80 MB in
// large files, a handful of mid-sized ones and a long tail of small packages whose grouped bytes churn a little.
func stallionPkgs() (old, walk map[string]int64) {
	old = map[string]int64{
		"com.example.biggame":     83_886_080, // ~80 MB of large files: the one that matters
		"com.example.maps":        21_000_000,
		"com.example.podcasts":    14_500_000,
		"com.example.notes":       9_800_000,
		"com.atomczak.notepat":    40_960,
		"com.android.inputmethod": 12_288,
	}
	for i := 0; i < 30; i++ {
		old[fmt.Sprintf("com.tail.app%02d", i)] = 8_000 + int64(i)*100
	}
	walk = map[string]int64{
		"com.atomczak.notepat":    40_960,
		"com.android.inputmethod": 12_288,
		"com.example.notes":       2_100_000, // short, not gone
	}
	for i := 0; i < 30; i++ {
		b := 8_000 + int64(i)*100
		if i%3 == 0 {
			b -= 7 // pro-rata churn in the grouped small-file tail: short by a few bytes
		}
		walk[fmt.Sprintf("com.tail.app%02d", i)] = b
	}
	return old, walk
}

func TestShrinkShortfall_StallionShapeNamesTheMissingPackageFirst(t *testing.T) {
	old, walk := stallionPkgs()
	head, entries := shrinkShortfall(old, walk, nil, nil, true, false)
	t.Logf("header: %s", head)
	for i, e := range entries {
		t.Logf("  [%d] %s", i+1, e)
	}
	if len(entries) == 0 || entries[0] != "com.example.biggame 83886080B->0B (gone)" {
		t.Fatalf("the ~80 MB package is not named FIRST with its bytes -- the one fact the refusal exists to give: %q", entries)
	}
	for _, want := range []string{"com.example.maps 21000000B->0B (gone)", "com.example.notes 9800000B->2100000B"} {
		if !strings.Contains(strings.Join(entries, "\n"), want) {
			t.Errorf("missing %q: %q", want, entries)
		}
	}
	// 3 gone + 1 short + 10 churned tail packages are short; only shrinkShortfallTop are listed and the rest counted.
	if !strings.Contains(head, "14 of the stored head's 36 package(s) are short") ||
		!strings.Contains(head, fmt.Sprintf("+%d more not listed", 14-shrinkShortfallTop)) {
		t.Errorf("the header does not count the short packages or the unlisted remainder:\n%s", head)
	}
	if len(entries) != shrinkShortfallTop {
		t.Errorf("listed %d packages, want exactly the top %d", len(entries), shrinkShortfallTop)
	}
	for _, unchanged := range []string{"com.atomczak.notepat", "com.android.inputmethod"} {
		if strings.Contains(head+strings.Join(entries, ""), unchanged) {
			t.Errorf("%s holds all its stored bytes and must not be listed", unchanged)
		}
	}
}

// renderRefusal builds the lines pushProfile prints for a len(seen)==0 refusal, from the same helpers it uses.
func renderRefusal(prof string, old, walk map[string]int64) []string {
	refusal := fmt.Sprintf("push: profile %s SEAL REFUSED -- walked 933 entries/218 files/3160652B but NONE >=1048576B "+
		"(0 via .under), so the 2-chunk manifest cannot account for a stored head of 124 chunks; the stored copy is intact "+
		"and untouched. Shrink accounting: %s", prof, shrinkRefusalNumbers(0, 0, 82_650_477, 136_000_000, 53_349_523))
	head, entries := shrinkShortfall(old, walk, nil, nil, true, false)
	return append([]string{refusal}, shrinkShortfallLog(prof, head, entries)...)
}

// THE LINES HAVE TO SURVIVE THE TICKET. On a user build the refusal reaches anyone only through REPORT-ISSUE, whose
// scrub rewrites bare 7+ digit runs to <num>, redacts quoted tokens and key=value secrets, and drops whole lines
// holding a drop keyword. Push the exact lines through it and require the package and every number to come out.
func TestShrinkShortfall_SurvivesTheIssueReportScrub(t *testing.T) {
	old, walk := stallionPkgs()
	got := strings.Join(scrubIssueLines(renderRefusal(`"alice" p:1a2b #de`, old, walk), []string{"alice"}), "\n")
	t.Logf("as a ticket carries it:\n%s", got)
	for _, want := range []string{"SEAL REFUSED", "dropped 0B + deferred-migrated 0B vs 82650477B lost",
		"shrink shortfall [1/8]: com.example.biggame 83886080B->0B (gone)", "com.example.notes 9800000B->2100000B"} {
		if !strings.Contains(got, want) {
			t.Errorf("the scrub mangled or dropped %q -- the ticket would arrive without it", want)
		}
	}
	if strings.Contains(got, "alice") {
		t.Errorf("the profile name survived the scrub:\n%s", got)
	}
}

// A PACKAGE NAME IS NOT OURS TO CHOOSE, and the scrub drops a whole line for a keyword in it. With the list on the
// refusal line, a password manager in the top 8 deleted the REFUSAL from the ticket. Now it costs one entry, and
// the [i/n] numbering shows the gap.
func TestShrinkShortfall_ADropKeywordPackageCostsOnlyItsOwnEntry(t *testing.T) {
	old, walk := stallionPkgs()
	const pm = "com.nordpass.android.app.password.manager"
	old[pm] = 30_000_000 // second-largest shortfall: lands as [2/8]
	got := scrubIssueLines(renderRefusal(`"alice" p:1a2b #de`, old, walk), []string{"alice"})
	joined := strings.Join(got, "\n")
	t.Logf("as a ticket carries it:\n%s", joined)
	if !strings.Contains(joined, "SEAL REFUSED") || !strings.Contains(joined, "82650477B lost") {
		t.Fatalf("the refusal line itself was dropped by the scrub -- the drop keyword took the whole verdict with it")
	}
	if strings.Contains(joined, "nordpass") {
		t.Errorf("the keyword line survived; this test then proves nothing about what a drop costs")
	}
	for _, want := range []string{"shrink shortfall: 15 of the stored head's 37", "[1/8]: com.example.biggame", "[3/8]: com.example.maps",
		"a missing [i/n] did not reach this copy"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q: one bad name must cost its own entry and nothing else", want)
		}
	}
	if strings.Contains(joined, "[2/8]") {
		t.Errorf("the dropped entry's number is still present, so the gap that makes the loss visible is gone")
	}
}

func TestShrinkShortfall_WhatItCannotShowItSays(t *testing.T) {
	for _, old := range []map[string]int64{nil, {}} {
		head, entries := shrinkShortfall(old, map[string]int64{"com.a.b": 1}, nil, nil, true, false)
		if !strings.Contains(head, "UNKNOWN") || !strings.Contains(head, "no Pkg index") || !strings.Contains(head, "does NOT mean none did") || entries != nil {
			t.Errorf("a head with no Pkg index must say the comparison is impossible, not print an empty list:\n%q %q", head, entries)
		}
	}
	old, _ := stallionPkgs()
	if head, entries := shrinkShortfall(old, nil, nil, nil, false, false); !strings.Contains(head, "NOT MEASURED") || entries != nil {
		t.Errorf("a NOWHERE_SEAL_FULL walk must not convict every package:\n%s %q", head, entries)
	}
	// #media: a top-level folder with a dot indexes as a "package", so names are withheld there -- counted, never named.
	head, entries := shrinkShortfall(map[string]int64{"Therapy.Notes": 40_000_000, "com.whatsapp": 9_000_000}, nil, nil, nil, true, true)
	if strings.Contains(head, "Therapy") || entries != nil || !strings.Contains(head, "names WITHHELD on #media") ||
		!strings.Contains(head, "2 of the stored head's 2 indexed name(s) are short") || !strings.Contains(head, "by 40000000B") {
		t.Errorf("#media must count the shortfall and withhold every name:\n%s %q", head, entries)
	}
}

// DEFERRED IS ONLY CLAIMED WHEN THE BYTES WENT THERE. deferredMap also carries forward old entries the walk never
// saw, so a package whose essential bytes vanished while an old OBB rode along is GONE, not "deferred now". And the
// tag uses the guard's own presence rule, so it cannot contradict an "unexplained: [...]" line beside it.
func TestShrinkShortfall_DeferredOnlyWhenTheGrowthCoversTheShortfall(t *testing.T) {
	d := func(sz int64) deferredFile { return deferredFile{Size: sz} }
	old := map[string]int64{"com.media.heavy": 50_000_000, "com.example.biggame": 83_886_080, "com.held.app": 20_000_000, "com.small.app": 4_096}
	walk := map[string]int64{"com.small.app": 4_096}
	oldDef := map[string]deferredFile{"com.example.biggame/files/main.obb": d(1_000_000)}
	newDef := map[string]deferredFile{}
	newDef["com.example.biggame/files/main.obb"] = d(1_000_000)                        // carried forward, unchanged
	newDef["com.media.heavy/files/video.mp4"] = d(60_000_000)                          // genuinely tiered out
	newDef["com.nowhere.chooser/.nowhere-odhold/com.held.app/files/x"] = d(25_000_000) // the hold shape: present by attrPkgForRel only
	_, entries := shrinkShortfall(old, walk, oldDef, newDef, true, false)
	got := strings.Join(entries, "\n")
	t.Logf("%s", got)
	for _, want := range []string{"com.media.heavy 50000000B->0B (deferred now)",
		"com.example.biggame 83886080B->0B (gone; 1000000B still deferred)",
		"com.held.app 20000000B->0B (gone; 25000000B still deferred)"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q", want)
		}
	}
	// The inferred-intent verdict, on the same manifests, names com.held.app as unexplained -- so this list must not
	// call it deferred.
	rels := make([]string, 0, len(newDef))
	for rel := range newDef {
		rels = append(rels, rel)
	}
	_, unexplained := shrinkIntentAllowed("inferred", nil, old, walk, rels)
	if !strings.Contains(strings.Join(unexplained, " "), "com.held.app") {
		t.Fatalf("fixture assumption broken: the verdict no longer names com.held.app unexplained (%v)", unexplained)
	}
}

func TestShrinkRefusalNumbers_SayWhatTheBytesShow(t *testing.T) {
	if got := shrinkRefusalNumbers(0, 0, 82_650_477, 1, 1); got != "dropped 0B + deferred-migrated 0B vs 82650477B lost, so neither accounts for it; per-package shortfall on the next line(s)" {
		t.Errorf("a byte loss: %q", got)
	}
	got := shrinkRefusalNumbers(0, 0, -512, 3_000, 3_512)
	if strings.Contains(got, "-512") || !strings.Contains(got, "did not shrink (head 3000B, walk 3512B)") || !strings.Contains(got, "chunk-count collapse only") {
		t.Errorf("a chunk-only collapse must not print a negative loss: %q", got)
	}
}

// END TO END: both refusal arms of the real guard, on real seals. One fixture serves both because a refusal
// leaves the stored head untouched. A package of large files goes first (the default arm: one large file is
// still walked), then the last large file (the len(seen)==0 arm, the stallion arm). A password manager rides in
// the vanished set, so the test also proves the REFUSAL LINE survives the scrub with it in the list.
func TestShrinkRefusal_EveryArmPrintsTheNumbersAndThePackages(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "") // receipt gate inert: the shrink guard is the subject
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	a, _ := twoWriters(t, "refusedetail", "correct horse battery staple")

	const pm = "com.nordpass.android.app.password.manager"
	big := []string{"a", "b", "c", "d", "e", "f", "g", "h"}
	for _, n := range big {
		a.put("com.example.biggame/files/"+n+".bin", detailBlob("biggame"+n, 3<<20))
	}
	a.put(pm+"/files/vault.bin", detailBlob("pm", 2<<20))
	a.put("com.example.other/files/keep.bin", detailBlob("other", 1200<<10))
	a.put("com.example.small/shared_prefs/p.xml", "<map/>")
	if msg := a.seal("#de"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	head := headManifestOf(t, a.base, a.name+"#de", a.pass)
	gameB, otherB := head.Pkg["com.example.biggame"], head.Pkg["com.example.other"]
	if len(head.Chunks) < 25 || gameB == 0 || otherB == 0 || head.Pkg[pm] == 0 {
		t.Fatalf("the fixture did not produce a head this test can use: %d chunks, Pkg=%v", len(head.Chunks), head.Pkg)
	}

	// Arm 1 -- the default arm: the game's and the password manager's dirs are gone, one large file is still walked.
	// The whole package dir, as a framework destroy takes it: an empty dir left behind would still contribute
	// tar-header bytes to the grouped tail and the package would read as short rather than gone.
	for _, d := range []string{"com.example.biggame", pm} {
		if err := os.RemoveAll(filepath.Join(a.work, d)); err != nil {
			t.Fatal(err)
		}
	}
	var msg string
	out := captureStdout(t, func() { msg = a.seal("#de") })
	if msg == "" {
		t.Fatalf("losing ~26 MB of a ~27 MB head was ACCEPTED -- the guard this test reads is not firing:\n%s", out)
	}
	t.Logf("default arm:\n%s", out)
	assertRefusalDetail(t, "default arm", out, "<< current", fmt.Sprintf("com.example.biggame %dB->0B (gone)", gameB))

	// Arm 2 -- len(seen)==0: no file >= 1 MiB is left at all.
	if err := os.RemoveAll(filepath.Join(a.work, "com.example.other")); err != nil {
		t.Fatal(err)
	}
	out = captureStdout(t, func() { msg = a.seal("#de") })
	if msg == "" {
		t.Fatalf("a walk with no large file left was ACCEPTED over a %d-chunk head:\n%s", len(head.Chunks), out)
	}
	t.Logf("seen==0 arm:\n%s", out)
	assertRefusalDetail(t, "len(seen)==0 arm", out, "NONE >=", fmt.Sprintf("com.example.biggame %dB->0B (gone)", gameB))
	if !strings.Contains(out, fmt.Sprintf("com.example.other %dB->0B (gone)", otherB)) {
		t.Errorf("len(seen)==0 arm: the second vanished package is not named")
	}
}

// #media withholds names in the real seal too: the scope is decided by pushProfile, not by the helper's caller.
func TestShrinkRefusal_MediaWithholdsFolderNames(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0") // keep the folder essential, so the Pkg index carries it
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "")
	t.Setenv("NOWHERE_SEAL_FORCE", "")
	t.Setenv("NOWHERE_SEAL_FULL", "")
	a, _ := twoWriters(t, "refusemedia", "correct horse battery staple")
	for _, n := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		a.put("Therapy.Notes/"+n+".bin", detailBlob("therapy"+n, 3<<20))
	}
	a.put("Download/readme.txt", "small")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	head := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if head.Pkg["Therapy.Notes"] == 0 || len(head.Chunks) < 20 {
		t.Fatalf("the fixture's #media head does not index the folder as a package (%d chunks, Pkg=%v): nothing to withhold", len(head.Chunks), head.Pkg)
	}
	if err := os.RemoveAll(filepath.Join(a.work, "Therapy.Notes")); err != nil {
		t.Fatal(err)
	}
	var msg string
	out := captureStdout(t, func() { msg = a.seal("#media") })
	if msg == "" {
		t.Fatalf("the #media collapse was accepted:\n%s", out)
	}
	t.Logf("%s", out)
	if strings.Contains(out, "Therapy") {
		t.Errorf("a #media folder name reached the log:\n%s", out)
	}
	if !strings.Contains(out, "names WITHHELD on #media") {
		t.Errorf("the #media refusal does not say it withheld the names:\n%s", out)
	}
}

func detailBlob(tag string, n int) string {
	b := make([]byte, n)
	seed := uint32(len(tag))*2654435761 + uint32(tag[len(tag)-1])
	for i := range b {
		seed = seed*1664525 + 1013904223
		b[i] = byte(seed >> 24)
	}
	return string(b)
}

var reRefusalNumbers = regexp.MustCompile(`dropped \d+B \+ deferred-migrated \d+B vs \d+B lost`)

// assertRefusalDetail checks one arm's output: the refusal line carries the numbers and NOT the list, the list
// follows on its own lines and names pkg, and after the issue scrub the refusal line is still there.
func assertRefusalDetail(t *testing.T, arm, out, marker, pkg string) {
	t.Helper()
	var refusal string
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, "SEAL REFUSED") && strings.Contains(ln, marker) {
			refusal = ln
		}
	}
	if refusal == "" {
		t.Fatalf("%s: no SEAL REFUSED line containing %q:\n%s", arm, marker, out)
	}
	if !reRefusalNumbers.MatchString(refusal) {
		t.Errorf("%s: the refusal does not print sealDropped, defMigrated and lost -- the comparison that brought it here:\n%s", arm, refusal)
	}
	if strings.Contains(refusal, "B->") {
		t.Errorf("%s: the package list rides the refusal line, where one keyword in a package name drops the verdict:\n%s", arm, refusal)
	}
	if !strings.Contains(out, "shrink shortfall [1/") || !strings.Contains(out, pkg) {
		t.Errorf("%s: the vanished package is not named with its stored bytes on a shortfall line (%q)", arm, pkg)
	}
	if strings.Count(out, "refusedetail") != strings.Count(out, `"refusedetail"`) {
		t.Errorf("%s: the profile name appears outside logProfile's quotes", arm)
	}
	scrubbed := strings.Join(scrubIssueLines(strings.Split(strings.TrimSpace(out), "\n"), []string{"refusedetail"}), "\n")
	if !strings.Contains(scrubbed, "SEAL REFUSED") || !reRefusalNumbers.MatchString(scrubbed) {
		t.Errorf("%s: after the issue scrub the refusal line is gone -- a package name in the list took it:\n%s", arm, scrubbed)
	}
}
