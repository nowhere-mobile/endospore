package main

import "testing"

// The scrub must not destroy what makes a denial ACTIONABLE. A rule needs scontext, tcontext, tclass and the
// permission; if the redaction eats those, the report is as useless as the "Permission denied" lines we
// already had (DIA-20260806-04).
func TestScrubKeepsWhatAPolicyRuleNeeds(t *testing.T) {
	in := []string{
		`avc: denied { search } for comm="nowhere_roamd.sh" name="11" dev="dm-49" ino=1441793 ` +
			`scontext=u:r:endospore_priv:s0 tcontext=u:object_r:system_data_file:s0:c512,c768 tclass=dir permissive=0`,
		`avc: denied { chown } for comm="chown" capability=0 scontext=u:r:endospore_priv:s0 ` +
			`tcontext=u:r:endospore_priv:s0 tclass=capability permissive=0`,
	}
	got := scrubIssueLines(in, []string{"alice"})
	if len(got) != len(in) {
		t.Fatalf("denials were dropped: kept %d of %d -- %v", len(got), len(in), got)
	}
	for _, want := range []string{"scontext=u:r:endospore_priv:s0", "tclass=dir", "denied { search }", "denied { chown }"} {
		found := false
		for _, ln := range got {
			if contains(ln, want) {
				found = true
			}
		}
		if !found {
			t.Errorf("the scrub removed %q, which is exactly what the rule is written from:\n  %v", want, got)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
