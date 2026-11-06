package main

import (
	"strings"
	"testing"
)

// #87 (NWP-20260903-18): a support ticket must say WHICH IMAGE the device runs.
//
// The chooser sends os_build = Build.FINGERPRINT because the confined daemon cannot reach the Android build
// APIs. Every caller status value is scrubbed, and the scrub ends with reIssueDigits -- the plain-digit
// phone-number backstop, `\b\d{7,}\b` -- which matches exactly one run in a fingerprint: the
// INCREMENTAL slot, i.e. our 10-digit BUILD_NUMBER. So every ticket ever filed hid the build. On a locked
// user build the issue reporter is the ONLY diagnostic channel there is.
//
// What these tests pin is the SHAPE of the exemption, because the shape is the whole safety argument: the
// pass-through is anchored to a WHOLE value and lives at the caller-status boundary ONLY. The user note and
// the log lines -- the two surfaces an untrusted party writes -- must keep their full scrub.

const (
	testFP = "google/lynx/lynx:17/CP2A.260605.012/2026090202:userdebug/release-keys"
	testBN = "2026090202"
)

// --- the bug itself -------------------------------------------------------------------------------------

func TestStatusValueKeepsTheBuildNumber(t *testing.T) {
	got := statusValue(testFP, nil)
	if !strings.Contains(got, testBN) {
		t.Fatalf("the build number is what the ticket exists to carry, and it was scrubbed: %q", got)
	}
	if got != testFP {
		t.Fatalf("a well-formed fingerprint must survive verbatim: %q", got)
	}
}

func TestEveryBuildTypeIsRecognised(t *testing.T) {
	// A fielded device is a `user` build; lynx is `userdebug`. Recognising only the one in front of me is
	// how this bug would come back for the fleet while every dev device looked fine.
	for _, ty := range []string{"user", "userdebug", "eng"} {
		fp := "google/lynx/lynx:17/CP2A.260605.012/" + testBN + ":" + ty + "/release-keys"
		if got := statusValue(fp, nil); got != fp {
			t.Errorf("build type %s not recognised: %q", ty, got)
		}
	}
}

// --- the safety argument --------------------------------------------------------------------------------

func TestOnlyAWholeValueIsExempt(t *testing.T) {
	// The anchoring is the containment. If the pattern could match a SUBSTRING, any free-form text that
	// merely embedded a fingerprint-shaped run would carry whatever else it contained straight out.
	for _, v := range []string{
		"running " + testFP,
		testFP + " call 4155550123",
		"build=" + testFP + " phone 4155550123",
	} {
		got := statusValue(v, nil)
		if strings.Contains(got, "4155550123") || got == v {
			t.Errorf("a value that merely CONTAINS a fingerprint must still be scrubbed: %q -> %q", v, got)
		}
	}
}

func TestTheGenericScrubIsUnchanged(t *testing.T) {
	// The exemption lives at the caller-status boundary ONLY. redactIssueSecrets also scrubs the user NOTE
	// and the log lines, where the text is written by someone we do not trust -- if the fingerprint rule
	// ever migrates in there, a note is all it takes to smuggle a number out.
	if got := redactIssueSecrets(testFP, nil); strings.Contains(got, testBN) {
		t.Fatalf("the fingerprint exemption has leaked into the generic scrub (note + log path): %q", got)
	}
}

func TestNonFingerprintValuesKeepTheirScrub(t *testing.T) {
	cases := map[string]string{
		"call me on 4155550123":                    "4155550123",
		"imei 490154203237518":                     "490154203237518",
		"a/b/c:1/d/4155550123:notatype/x":          "4155550123",
		"google/lynx/lynx:17/CP2A/4155550123:user": "4155550123",
	}
	for in, mustGo := range cases {
		if got := statusValue(in, nil); strings.Contains(got, mustGo) {
			t.Errorf("digits survived a NON-fingerprint status value: %q -> %q", in, got)
		}
	}
}

func TestProfileNameStillRedactedInStatus(t *testing.T) {
	// The literal-secret pass is skipped for a matched fingerprint (it would mangle the build of a device
	// whose profile is named after a fingerprint token, and protects nothing). It must still run for
	// everything else.
	if got := statusValue("context: alice signed in", []string{"alice"}); strings.Contains(got, "alice") {
		t.Fatalf("the profile name survived a non-fingerprint status value: %q", got)
	}
}

func TestFingerprintSurvivesAProfileNamedAfterIt(t *testing.T) {
	// A profile called "lynx" must not shred the build string -- and cannot be disclosed by it, since the
	// fingerprint reads the same whatever the profile is called.
	if got := statusValue(testFP, []string{"lynx"}); got != testFP {
		t.Fatalf("a profile named after a fingerprint token mangled the build: %q", got)
	}
}

// --- end to end -----------------------------------------------------------------------------------------

func TestReportCarriesTheBuildNumber(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	rep := buildIssueReport("alice", false, "", map[string]string{"os_build": testFP}, nil)
	if got := rep.Status["os_build"]; !strings.Contains(got, testBN) {
		t.Fatalf("the assembled report still hides the build number: os_build=%q", got)
	}
}
