package main

import (
	"strings"
	"testing"
)

// DIA-20260812-10 (#118). roamd may now append " PARTIAL:<scope>=<cause>,..." to ANY verdict, because #sys,
// #apps and #keys are sealed by helpers that deliberately do not fail the data seal -- and that was implemented
// by discarding their return values, so the identical guards that produce ERR-REFUSED on the vault fired
// SILENTLY on those three. The suffix only works if every reader matches on the VERB; these tests pin that.

func TestSealPartsOfExtractsTheDetail(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"OK", ""},
		{"OK PARTIAL:apps=refused", "apps=refused"},
		{"OK PARTIAL:apps=refused,sys=timeout", "apps=refused,sys=timeout"},
		{"ERR-NOCREDIT PARTIAL:vault=nocredit,apps=refused", "vault=nocredit,apps=refused"},
		// NWP-20261008-07: a pending account placement is not something unstored, alone or beside one that is.
		{"OK PARTIAL:sys=pending-placement", ""},
		{"OK PARTIAL:apps=refused,sys=pending-placement", "apps=refused"},
		{"OK PARTIAL:sys=pending-placement,keys=notsealed", "keys=notsealed"},
		{"OK PARTIAL:sys=timeout", "sys=timeout"}, // a #sys that really did not store still says so
		{"ERR-REFUSED", ""},
		{"ERR-PUSH", ""},
		{"", ""},
	} {
		if got := sealPartsOf(c.in); got != c.want {
			t.Errorf("sealPartsOf(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSealVerbStripsTheDetail(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"OK", "OK"},
		{"OK PARTIAL:apps=refused", "OK"},
		{"ERR-NOCREDIT PARTIAL:apps=refused", "ERR-NOCREDIT"},
		{"ERR-REFUSED PARTIAL:sys=refused", "ERR-REFUSED"},
		{"ERR-PUSH", "ERR-PUSH"},
	} {
		if got := sealVerb(c.in); got != c.want {
			t.Errorf("sealVerb(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRecordSealStillClassifiesAVerdictCarryingAPartial(t *testing.T) {
	// The regression this guards is precise and was live in the first draft of #118: recordSeal matched
	// `out == "ERR-NOCREDIT"` EXACTLY. The moment a co-occurring #apps refusal appended a suffix, that
	// comparison stopped matching and the verdict fell through to "fail" -- i.e. adding per-scope detail would
	// have silently downgraded a credit failure into "check your connection", the exact bug #111 fixed.
	for _, c := range []struct{ out, want string }{
		{"OK PARTIAL:apps=refused", "ok"},
		{"ERR-NOCREDIT PARTIAL:apps=refused", "nocredit"},
		{"ERR-REFUSED PARTIAL:sys=refused", "refused"},
		{"ERR-PUSH PARTIAL:apps=timeout", "fail"},
		{"OK", "ok"},
		{"ERR-NOCREDIT", "nocredit"},
		{"ERR-REFUSED", "refused"},
	} {
		recordSeal(c.out)
		if got := sealStatusGet(); got != c.want {
			t.Errorf("recordSeal(%q) -> %q, want %q", c.out, got, c.want)
		}
	}
}

func TestRecordSealKeepsThePartsForTheStatusVerb(t *testing.T) {
	recordSeal("OK PARTIAL:apps=refused,sys=timeout")
	if got := sealPartsGet(); got != "apps=refused,sys=timeout" {
		t.Errorf("sealPartsGet() = %q after a partial, want the scope list", got)
	}
	// A later CLEAN seal must clear it, or the notice would keep naming scopes that have since sealed.
	recordSeal("OK")
	if got := sealPartsGet(); got != "" {
		t.Errorf("sealPartsGet() = %q after a clean seal, want \"\" -- a stale partial would outlive its cause", got)
	}
}

func TestSealFailSuffixStillMatchesWhenAPartialRidesAlong(t *testing.T) {
	// #111's suffix and #118's suffix must compose: FAILED REFUSED is still derivable from a verdict that also
	// carries a scope list, otherwise the logoff screen falls back to the generic connection advice.
	if got := sealFailSuffix("ERR-REFUSED PARTIAL:apps=refused"); got != "REFUSED" {
		t.Errorf("sealFailSuffix with a partial = %q, want REFUSED", got)
	}
	if got := sealFailSuffix("ERR-NOCREDIT PARTIAL:apps=refused"); got != "NOCREDIT" {
		t.Errorf("sealFailSuffix with a partial = %q, want NOCREDIT", got)
	}
}

// NWP-20261008-07: the "Back up now" line names a partial in the user's terms, never the raw token.
func TestBackupLineNamesPartsInTheUsersTerms(t *testing.T) {
	prof := chooserCode(t, "ProfileActivity.java")
	if !strings.Contains(prof, `st.setText("Backed up — except " + partialWhat(verdict.substring("DONE PARTIAL:".length()).trim())`) {
		t.Fatal(`the "Back up now" line no longer renders a partial through partialWhat: it would print raw scope tokens`)
	}
}
