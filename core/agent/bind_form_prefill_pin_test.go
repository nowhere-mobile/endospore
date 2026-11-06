package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261006-01: binding a co-owner rewrites the line's label and visibility (setBindingOwner sets both on every
// bind), and the gate's bind form opened with a blank label and "Open". So adding a second profile to a line labelled
// "Work" unlabelled it, and a "Private" line went "Open". The form now opens with the line's current values. Pinned
// from the chooser source, which has no Java test surface: each half is one line that would silently regress.
func TestBindFormOpensWithTheLinesLabelAndVisibility(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ChooserActivity.java"))
	if err != nil {
		t.Fatalf("ChooserActivity.java must be readable from core/agent: %v", err)
	}
	src := string(b)
	for _, want := range []string{
		`f[4].trim() + " bound · " + f[3].trim(), label, f[3].trim() });`, // GET-BINDINGS keeps the label and visibility
		`if (hit.length >= 5) { fs.label = hit[3]; fs.vis = hit[4]; }`,    // the SIM row hands them to its form
		`labelF.setText(sim.label);`,                                      // the label field starts filled
		`final String[] vis = {"notify".equals(sim.vis) || "private".equals(sim.vis) ? sim.vis : "open"};`,
		`chip.setTextColor(vis[0].equals(o[0]) ? ACCENT : MUTED);`, // and the chip that is lit is the line's own
	} {
		if !strings.Contains(src, want) {
			t.Errorf("the bind form no longer carries the line's current values: missing %q", want)
		}
	}
	if strings.Contains(src, `final String[] vis = {"open"};`) {
		t.Error(`the bind form's visibility is hard-coded to "open" again`)
	}
}

// NWP-20261011-19: the SIM label is base64 on both owner-mode verbs. A stored label can hold '|' or a newline
// (bindings.conf base64s it, so setBindingOwner stores one), and raw it split GET-BINDINGS' line into the wrong fields
// and shifted SET-BINDING's request lines. The daemon side is tested in telephony_v2_test.go; the chooser side is
// pinned here from the source, which has no Java test surface.
func TestTheSIMLabelIsBase64OnBothSidesOfTheWire(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ChooserActivity.java"))
	if err != nil {
		t.Fatalf("ChooserActivity.java must be readable from core/agent: %v", err)
	}
	src := string(b)
	for _, want := range []string{
		// bindingSummaries decodes the label, and a field that does not decode is a damaged line, not "not bound"
		`label = new String(android.util.Base64.decode(f[2], android.util.Base64.DEFAULT), java.nio.charset.StandardCharsets.UTF_8);`,
		`catch (IllegalArgumentException e) { out.add(TelArrival.DAMAGED_ROW); continue; }`,
		// the bind button sends the label it chose (BindFormFields.forBind) encoded
		`"SET-BINDING\n" + sim.subId + "\n" + iccid + "\n" + android.util.Base64.encodeToString(f[0].getBytes(java.nio.charset.StandardCharsets.UTF_8), android.util.Base64.NO_WRAP) + "\n" + f[1] + "\n"`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("the SIM label is not base64 on the owner-mode wire: missing %q", want)
		}
	}
	for _, raw := range []string{
		`"\n" + iccid + "\n" + label + "\n"`, // the label sent raw
		`, f[2], f[3].trim() });`,            // the label read raw
	} {
		if strings.Contains(src, raw) {
			t.Errorf("the SIM label is raw on the owner-mode wire again: found %q", raw)
		}
	}
}
