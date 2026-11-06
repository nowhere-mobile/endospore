package main

// NWP-20260921-11: where the chooser sends someone who wants to BUY storage.
//
// Chester reported it on 2026-09-21: "on beta os, Profile->Storage->Plans & buying storage is all
// pointing to prod." It was NOT a misconfiguration -- there was nothing to configure. The chooser held a
// compile-time constant (`PLANS_URL = "https://nowhere.mobile/buy"`, ProfileActivity.java) and no
// ring-aware storefront key existed anywhere in the tree: no conf key, no ring template line, no
// property, no daemon op. A beta image therefore had no mechanism by which it could point anywhere else.
//
// ⚠ WHY THE DAEMON OWNS THIS AND NOT THE CHOOSER. The value has to come from the MERGED conf. The
// device's /data/nowhere/nowhere.conf and the baked ring /system/etc/nowhere/nowhere.conf are merged
// (NWP-20260908-06), so a chooser that read /system directly would miss a device override -- and it was
// precisely the pre-merge "replace" behaviour that kept NOWHERE_SEQ_GUARD inert on every fielded handset
// for an evening. The daemon already holds the merged environment, so it is the only place that can
// answer correctly.
//
// ⚠ AND WHY IT IS AN ORIGIN, NOT A FULL URL. The caller appends its own path (/buy), so the two halves
// cannot drift apart the way a second constant would. That also keeps this key useful for any later
// storefront destination without inventing a key per page.

import (
	"os"
	"strings"
)

// storefrontDefault is what a device with NO ring configuration uses. Prod bakes no ring, so this
// constant IS prod's behaviour -- which is what makes STOREFRONT_URL a purely additive key rather than a
// change to the shipped product.
const storefrontDefault = "https://nowhere.mobile"

// storefrontURL returns the storefront ORIGIN for this device, with no trailing slash and no path.
//
// It never returns empty: an unset, blank or whitespace-only value falls back to the shipped default,
// because the caller renders this into a QR code and an "Open the website" button, and a blank there
// would be a dead control rather than a visible failure.
func storefrontURL() string {
	v := strings.TrimSpace(os.Getenv("STOREFRONT_URL"))
	if v == "" {
		return storefrontDefault
	}
	return strings.TrimRight(v, "/")
}
