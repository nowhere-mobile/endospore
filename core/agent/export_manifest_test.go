package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// NWP-20260919-08. The completeness index exists because sha256(bytes)==key proves integrity and says
// nothing about completeness. These tests are about the three things that make an index WRONG, because a
// wrong index is worse than none: it makes a bad copy look verified.

func manifestFixture() *ExportManifest {
	return &ExportManifest{
		Version: exportManifestVersion,
		Blobs: []ManifestBlob{
			{Key: "blob/" + strings.Repeat("a", 64), Size: 100},
			{Key: "blob/" + strings.Repeat("b", 64), Size: 200},
		},
		Refs: []ManifestRef{{Key: "ref/p:deadbeef", Value: strings.Repeat("c", 64)}},
	}
}

// A ref that is PRESENT but carries a different value must fail. This is the case no content check
// anywhere can catch, because a ref is not content-addressed.
func TestARefThatArrivedWithTheWrongValueIsNotAVerifiedCopy(t *testing.T) {
	m := manifestFixture()
	rep := &VerifyReport{}
	rep.WrongRefs = append(rep.WrongRefs, m.Refs[0].Key)
	if rep.ok() {
		t.Fatal("a report naming a WRONG ref passed ok() -- a stale or foreign head would be accepted as " +
			"a verified copy, and nothing downstream can tell")
	}
	if !strings.Contains(rep.summary(), "WRONG refs") {
		t.Fatalf("summary did not name the wrong ref: %q", rep.summary())
	}
}

// Each failure class must independently sink the verdict. If any one of them is dropped from ok(), a copy
// missing that class verifies green.
func TestEveryFailureClassSinksTheVerdictOnItsOwn(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(*VerifyReport)
	}{
		{"missing blob", func(r *VerifyReport) { r.MissingBlobs = []string{"blob/x"} }},
		{"missing ref", func(r *VerifyReport) { r.MissingRefs = []string{"ref/x"} }},
		{"wrong ref", func(r *VerifyReport) { r.WrongRefs = []string{"ref/x"} }},
		{"corrupt blob", func(r *VerifyReport) { r.CorruptBlobs = []string{"blob/x"} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &VerifyReport{}
			if !r.ok() {
				t.Fatal("an empty report must be the PASS -- otherwise nothing can ever verify")
			}
			tc.set(r)
			if r.ok() {
				t.Fatalf("a report with a %s passed ok() -- that class of incomplete copy verifies green", tc.name)
			}
		})
	}
}

// An index naming no refs has no head. It would verify green over a pile of blobs and restore nothing.
func TestAnIndexWithNoRefsIsRefusedRatherThanVerifiedGreen(t *testing.T) {
	m := manifestFixture()
	m.Refs = nil
	b, err := m.encode()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeExportManifest(b); err == nil {
		t.Fatal("an index naming no refs was accepted -- a copy made from it has no head and cannot be " +
			"logged into, but every blob in it would verify")
	}
}

// A future/unknown version must be refused, not partially understood. The whole value of the file is that
// a pass means something.
func TestAnUnknownManifestVersionIsRefusedNotPartiallyRead(t *testing.T) {
	m := manifestFixture()
	m.Version = exportManifestVersion + 1
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	_, err = decodeExportManifest(b)
	if err == nil {
		t.Fatal("a newer manifest version was accepted; this agent would verify the subset it recognises " +
			"and report success over whatever it did not")
	}
	if !strings.Contains(err.Error(), "version") {
		t.Fatalf("the refusal did not mention the version: %v", err)
	}
}

// Round-trip: what an export writes is what a restore reads.
func TestAManifestSurvivesItsOwnRoundTrip(t *testing.T) {
	m := manifestFixture()
	b, err := m.encode()
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeExportManifest(b)
	if err != nil {
		t.Fatalf("a manifest this agent wrote would not decode: %v", err)
	}
	if len(got.Blobs) != len(m.Blobs) || len(got.Refs) != len(m.Refs) {
		t.Fatalf("round trip lost entries: %d/%d blobs, %d/%d refs",
			len(got.Blobs), len(m.Blobs), len(got.Refs), len(m.Refs))
	}
	if got.Refs[0].Value != m.Refs[0].Value {
		t.Fatalf("the ref VALUE did not survive: %q != %q -- that field is the only thing that makes a "+
			"pointer checkable", got.Refs[0].Value, m.Refs[0].Value)
	}
}

// The summary must lead with the counts, so a pass is auditable rather than merely green -- the same rule
// verify-release.sh follows.
func TestThePassPrintsWhatItChecked(t *testing.T) {
	r := &VerifyReport{CheckedBlobs: 54, CheckedRefs: 5}
	s := r.summary()
	if !strings.Contains(s, "54") || !strings.Contains(s, "5") {
		t.Fatalf("summary hid what it checked: %q", s)
	}
	if !strings.Contains(s, "presence") {
		t.Fatalf("a shallow verify must SAY it was shallow, or a reader assumes the bytes were checked: %q", s)
	}
	if got := (&VerifyReport{DeepVerified: true}).summary(); !strings.Contains(got, "deep") {
		t.Fatalf("a deep verify must say so too: %q", got)
	}
}
