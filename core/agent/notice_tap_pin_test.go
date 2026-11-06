package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261006-04: the gate's unassigned-SIM notice leads to the owner inbox -- the decided route (2026-09-01, landing
// 2026-09-27). NWP-20261105-06 (Q064): the route also sits on the unassigned entry of the multi-notice popup. Its two
// hard constraints are pinned from the chooser source, which has no Java test surface:
//   - it lands ON the owner verify screen and never past it (the screens beyond show per-SIM owner counts and a full
//     ICCID), and only a successful verify opens the inbox;
//   - it is INERT without an owner secret.
func TestUnassignedNoticeTapGoesThroughVerify(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ChooserActivity.java"))
	if err != nil {
		t.Fatalf("ChooserActivity.java must be readable from core/agent: %v", err)
	}
	src := string(b)
	for _, want := range []string{
		`final String tap = NoticeTap.action(notices, ownerSecretSet());`,
		`if (NoticeTap.VERIFY.equals(tap)) noticeBanner.setOnClickListener(v -> setContentView(buildOwnerVerifyScreen(StoreGate.DEST_INBOX)));`,
		`else if (dest == StoreGate.DEST_INBOX) setContentView(buildOwnerInboxScreen());`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("the unassigned-notice route changed: missing %q", want)
		}
	}
	// Nothing reaches the inbox or the owner menu from the banner or its popup without the verify.
	for _, sig := range []string{"private void refreshNoticeBanner() {", "private void showNoticePopup() {"} {
		i := strings.Index(src, sig)
		if i < 0 {
			t.Fatalf("%s not found -- this test is stale", sig)
		}
		j := strings.Index(src[i:], "\n    }\n")
		if j < 0 {
			t.Fatalf("the end of %s not found -- this test is stale", sig)
		}
		body := src[i : i+j]
		for _, bad := range []string{"buildOwnerInboxScreen(", "buildOwnerMenu(", "buildOwnerEnrollScreen("} {
			if strings.Contains(body, bad) {
				t.Errorf("%s reaches %s without the owner verify", sig, bad)
			}
		}
	}
}
