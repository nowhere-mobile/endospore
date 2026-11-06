package main

import (
	"regexp"
	"strconv"
)

// logVal renders a daemon-produced verdict (roamd's cutoff verdict, a claim or release answer) for a log line
// (NWP-20261116-24). The sign-out scrub (LOG_SCRUB_SED rule 2, roamd) takes EVERY double-quoted token for a profile
// name, by design (NOWHERE-398), and Q001 (e) keeps the scrub as it is -- so a verdict printed with %q reached the
// field as `cutoff "<name>"`. A verdict is never a name, so it is printed with no double quote in it: the square
// brackets keep an empty or space-holding value readable (`[PARTIAL 189 2]`, `[-]` for empty), and `"`, `\` and
// every byte outside printable ASCII become `?`, so the line can never hold a quote the scrub would pair.
func logVal(s string) string {
	if s == "" {
		return "[-]"
	}
	b := []byte(s)
	for i, c := range b {
		if c < 0x20 || c > 0x7e || c == '"' || c == '\\' {
			b[i] = '?'
		}
	}
	return "[" + string(b) + "]"
}

// sysIfaceRe matches the interface names the platform itself assigns.
var sysIfaceRe = regexp.MustCompile(`^(wlan|rmnet|rmnet_data|ccmni|eth|rndis|usb|tun|seth_lte|v4-rmnet_data)[0-9]+$`)

// ifaceTok renders a network interface name for a log line (NWP-20261116-24). A platform interface (wlan0,
// rmnet_data3, tun0) is the diagnosis and is never a profile name, so it prints bare and survives the sign-out
// scrub. Any other name may be the user's own (a kernel WireGuard interface named for its tunnel, NOWHERE-982's
// class, see vpn_apply_choice), so it stays quoted (%q) and the scrub still replaces it.
func ifaceTok(s string) string {
	if sysIfaceRe.MatchString(s) {
		return s
	}
	return strconv.Quote(s)
}
