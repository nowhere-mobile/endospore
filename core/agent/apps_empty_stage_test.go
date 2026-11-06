package main

import "testing"

// NWP-20261025-04. appcode_seal now reaches the #apps push when the keep-set FILE exists and is empty (the
// chooser's record that the last kept app was uninstalled or switched Off), so the push it sends is an EMPTY
// stage: manifest.tsv and nothing else. These tests pin the agent side that change relies on, and they pass on
// origin/main too -- the agent is unchanged: the logoff's EXPECT-SHRINK marker lets the empty seal through and
// the new head names no package; with no marker and no drop list the same seal is refused.

func TestAppsEmptyStageIsAllowedUnderTheShrinkMarker(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "emptystagemarked", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.last")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	if err := markShrinkIntent(profileRefV2(name+"#apps", pass)); err != nil {
		t.Fatalf("fixture: arming the shrink marker: %v", err)
	}
	if refused := sealApps(t, base, name, pass, stageApps(t)); refused {
		t.Fatal("an EMPTY #apps stage under a deliberate marker was refused -- the last kept app, uninstalled or " +
			"switched Off, would come back at every login")
	}
	if m := headManifestOf(t, base, name+"#apps", pass); len(m.Pkg) != 0 {
		t.Fatalf("the sealed head still names packages: %v", m.Pkg)
	}
}

func TestAppsEmptyStageIsRefusedWithoutAMarker(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	const name, pass = "emptystageunmarked", "correct horse battery staple"
	createVault(base, name, pass)

	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.last")); refused {
		t.Fatal("fixture: the FIRST #apps seal was refused")
	}
	if refused := sealApps(t, base, name, pass, stageApps(t)); !refused {
		t.Fatal("an EMPTY #apps stage with no marker and no drop list was ACCEPTED -- a broken handset would wipe " +
			"the account's apps")
	}
}
