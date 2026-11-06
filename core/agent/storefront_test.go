package main

import (
	"os"
	"testing"
)

// NWP-20260921-11: the storefront origin the chooser buys against.
//
// ⚠ THE DEFAULT IS THE LOAD-BEARING CASE, not the configured one. Prod bakes no ring, so an unset
// STOREFRONT_URL has to keep behaving exactly like the compile-time constant this replaced -- if that
// regresses, every prod handset silently stops being able to buy storage, which is a worse bug than the
// beta one being fixed. The configured case only has to work for the beta ring.
func TestStorefrontURL(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  bool
		val  string
		want string
	}{
		{"unset falls back to prod", false, "", storefrontDefault},
		{"empty falls back to prod", true, "", storefrontDefault},
		{"whitespace only falls back to prod", true, "   ", storefrontDefault},
		{"configured origin is used", true, "https://beta.nowhere.mobile", "https://beta.nowhere.mobile"},
		{"surrounding whitespace is trimmed", true, "  https://beta.nowhere.mobile  ", "https://beta.nowhere.mobile"},
		// The caller appends "/buy", so a trailing slash would produce "…mobile//buy". A conf file edited
		// by hand is exactly where that typo comes from.
		{"one trailing slash is stripped", true, "https://beta.nowhere.mobile/", "https://beta.nowhere.mobile"},
		{"several trailing slashes are stripped", true, "https://beta.nowhere.mobile///", "https://beta.nowhere.mobile"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.set {
				t.Setenv("STOREFRONT_URL", tc.val)
			} else {
				// t.Setenv registers the restore, then Unsetenv makes it genuinely ABSENT -- which is a
				// different state from empty and is the one a prod device is actually in.
				t.Setenv("STOREFRONT_URL", "")
				if err := os.Unsetenv("STOREFRONT_URL"); err != nil {
					t.Fatal(err)
				}
			}
			if got := storefrontURL(); got != tc.want {
				t.Errorf("storefrontURL() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestStorefrontURLNeverReturnsEmpty is the property the caller actually depends on: it renders this into
// a QR code and an "Open the website" button, and a blank there is a DEAD CONTROL rather than a visible
// failure -- the user taps and nothing happens, with nothing on screen saying why.
func TestStorefrontURLNeverReturnsEmpty(t *testing.T) {
	for _, v := range []string{"", " ", "\t", "\n", "   \t  \n "} {
		t.Setenv("STOREFRONT_URL", v)
		if got := storefrontURL(); got == "" {
			t.Fatalf("storefrontURL() returned empty for %q -- the buy button would be dead", v)
		}
	}
}
