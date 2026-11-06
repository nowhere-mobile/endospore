package main

// NWP-20261114-13: the ring signal for the first-run OS agreement screen with DRAFT text (decided 2026-10-24,
// docs/product-decisions.md: "the first-boot OS agreement screen is built now with DRAFT text, shown on beta-ring
// images only behind one gate").
//
// ⚠ THE VALUE MARKS A RING IMAGE, NOTHING MORE. rings/beta-setup.conf bakes NOWHERE_OS_AGREEMENT=draft. Prod and
// stable bake no ring, so the key is absent there and the answer is "off": a production image never shows a DRAFT
// legal screen because of this key.
//
// ⚠ WHY THE DAEMON OWNS THE READ. The value has to come from the MERGED conf (the ring /system copy under the
// device's /data copy, NWP-20260908-06), and only the daemon holds the merged environment -- the storefront.go
// reason exactly.
//
// ⚠ THIS KEY IS NOT THE PRODUCTION SWITCH. The production switch is the chooser's single gate (G-02), and its
// flip is its own change that cites counsel's approval. Never set this key to put the screen on a production image.

import (
	"os"
	"strings"
)

// osAgreementMode returns "draft" when this image carries the DRAFT agreement screen, else "off".
//
// The match is exact and case-sensitive, so every near miss ("DRAFT", "on", "1", empty, unset) answers "off". A
// conf typo must fail toward production: it hides the DRAFT screen, it never shows it.
func osAgreementMode() string {
	if strings.TrimSpace(os.Getenv("NOWHERE_OS_AGREEMENT")) == "draft" {
		return "draft"
	}
	return "off"
}
