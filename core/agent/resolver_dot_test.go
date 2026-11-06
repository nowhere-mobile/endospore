package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// NWP-20260904-12: the agent resolver honours the device's strict private-DNS (DoT) posture.
//
// The fixtures extend the captured shapes in resolver_test.go with the fragments LinkProperties.toString()
// prints (packages/modules/Connectivity/framework/src/android/net/LinkProperties.java:950-972): after
// `DnsAddresses: [ ... ]` come `UsePrivateDns: true`, `PrivateDnsServerName: <host>` (strict mode only --
// DnsManager.updatePrivateDnsStatus:313) and `ValidatedPrivateDnsAddresses: [<ip>,<ip>]` (getHostAddress, no
// leading slash, no spaces), then `Domains: <x> MTU: <n>`.

// STRICT, validated: the provisioned posture (dns.mullvad.net) with Mullvad's addresses validated by the OS. The
// cellular block is listed FIRST and carries the same global posture -- the default-scoped parse must read the
// Wi-Fi block's, whose validated list differs from the cellular one (a v4-only radio validation).
const sampleDumpsysStrict = `Active default network: 121
NetworkAgentInfo{network{104} lp{{InterfaceName: rmnet17 ` +
	`DnsAddresses: [ /fc00:a:a::400,/172.26.38.2 ] UsePrivateDns: true PrivateDnsServerName: dns.mullvad.net ` +
	`ValidatedPrivateDnsAddresses: [194.242.2.2] Domains: null MTU: 1430}} ` +
	`NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /2001:4860:4860::8844,/192.0.2.53,/198.51.100.53 ] UsePrivateDns: true ` +
	`PrivateDnsServerName: dns.mullvad.net ValidatedPrivateDnsAddresses: [2a07:e340::2,194.242.2.2] ` +
	`Domains: null MTU: 1500 ServerAddress: /192.168.4.1}}`

// STRICT, blocked: the posture is set but the network blocks 853, so the OS has NOTHING validated (the
// backlog's "at work, they block private dns" case). The hostname is still printed; no validated list.
const sampleDumpsysStrictBlocked = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] UsePrivateDns: true PrivateDnsServerName: dns.mullvad.net ` +
	`Domains: null MTU: 1500 ServerAddress: /192.168.4.1}}`

// OPPORTUNISTIC, validated: UsePrivateDns without a hostname (updatePrivateDnsStatus prints the name for strict
// mode only). The OS upgrades best-effort; the agent stays plain, and the validated addresses are the network's
// own resolvers on 853.
const sampleDumpsysOpportunistic = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] UsePrivateDns: true ` +
	`ValidatedPrivateDnsAddresses: [192.0.2.53] Domains: null MTU: 1500 ServerAddress: /192.168.4.1}}`

// OFF: neither fragment.
const sampleDumpsysPrivateOff = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] Domains: null MTU: 1500 ServerAddress: /192.168.4.1}}`

// The default block listed FIRST with NO posture, followed by another network that HAS one. Only a parse
// bounded to the default's own NetworkAgentInfo reads "off" here; an unbounded search bleeds the second
// network's hostname into the first.
const sampleDumpsysScoped = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53 ] Domains: null MTU: 1500}} ` +
	`NetworkAgentInfo{network{104} lp{{InterfaceName: rmnet17 ` +
	`DnsAddresses: [ /172.26.38.2 ] UsePrivateDns: true PrivateDnsServerName: dns.mullvad.net Domains: null MTU: 1430}}`

// A connected VpnService network carrying the global strict posture, plus the physical underlay as the default.
const sampleDumpsysVpnStrict = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53 ] UsePrivateDns: true PrivateDnsServerName: dns.mullvad.net Domains: null MTU: 1500}} ` +
	`NetworkAgentInfo{network{130} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun0 ` +
	`DnsAddresses: [ /10.64.0.1 ] UsePrivateDns: true PrivateDnsServerName: dns.mullvad.net ` +
	`ValidatedPrivateDnsAddresses: [194.242.2.2] Domains: null MTU: 1280 Routes: [ 0.0.0.0/0 -> 0.0.0.0 tun0 mtu 0 ]}}`

// NWP-20260925-03: a session VPN that is a SPLIT tunnel. The layout is the Tailscale registration ConnectivityService
// logged on lynx 2026092603 on 2026-09-25 (no exit node selected); its tailnet addresses and name are replaced. The
// physical network carries a default route of its own, so a test that read routes from the WHOLE dump instead of
// the VPN's block would see a full tunnel and fail.
const sampleDumpsysVpnSplit = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.4.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{106} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun1 ` +
	`LinkAddresses: [ 100.64.0.10/32,fd7a:115c:a1e0::a/128 ] DnsAddresses: [ /100.100.100.100,/fd7a:115c:a1e0::53 ] ` +
	`Domains: example.ts.net MTU: 1280 Routes: [ 100.64.0.20/32 -> 0.0.0.0 tun1 mtu 0,100.64.0.30/32 -> 0.0.0.0 tun1 mtu 0,` +
	`100.100.100.100/32 -> 0.0.0.0 tun1 mtu 0,fd7a:115c:a1e0::/48 -> :: tun1 mtu 0 ] }}`

// The same VPN as a FULL tunnel -- an exit node selected -- adds the defaults to its OWN routes.
var sampleDumpsysVpnFull = strings.Replace(sampleDumpsysVpnSplit, "Routes: [ 100.64.0.20/32",
	"Routes: [ 0.0.0.0/0 -> 0.0.0.0 tun1 mtu 0,::/0 -> :: tun1 mtu 0,100.64.0.20/32", 1)

// The same split VPN in the user-switch window: no "Active default network" line and no physical DnsAddresses,
// so discoveredDNS's all-networks fallback sees only the VPN's own resolvers.
const sampleDumpsysVpnSplitNoDefault = `NetworkAgentInfo{network{106} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun1 ` +
	`LinkAddresses: [ 100.64.0.10/32 ] DnsAddresses: [ /100.100.100.100,/fd7a:115c:a1e0::53 ] ` +
	`Domains: example.ts.net MTU: 1280 Routes: [ 100.64.0.20/32 -> 0.0.0.0 tun1 mtu 0 ] }}`

// A split VPN whose resolver shares its address with the physical network's own (a home-LAN WireGuard config on a
// Wi-Fi that hands out the same router address): the physical resolver must still be used.
const sampleDumpsysVpnSplitSharedDNS = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{107} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun2 ` +
	`LinkAddresses: [ 10.9.0.2/32 ] DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1420 ` +
	`Routes: [ 192.168.1.0/24 -> 0.0.0.0 tun2 mtu 0 ] }}`

// A corporate split VPN on a home Wi-Fi: it routes all of RFC 1918 -- the Wi-Fi's own 192.168/16 included -- and has
// a resolver of its own. The physical router must still answer the daemon's lookups, out of wlan0: binding a
// resolver dial by destination would push every one into the tunnel, to a network with no such router. It is
// IPv4-only, so Android blocks IPv6 in it (`::/0 unreachable`, Vpn.makeLinkProperties) -- which, in a SPLIT tunnel,
// must not pull the daemon's IPv6 in with it.
const sampleDumpsysVpnCorp = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{109} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun5 ` +
	`LinkAddresses: [ 10.20.0.2/32 ] DnsAddresses: [ /10.0.0.53 ] Domains: corp.example MTU: 1400 ` +
	`Routes: [ 10.0.0.0/8 -> 0.0.0.0 tun5 mtu 0,172.16.0.0/12 -> 0.0.0.0 tun5 mtu 0,192.168.0.0/16 -> 0.0.0.0 tun5 mtu 0,` +
	`::/0 unreachable mtu 0 ] }}`

// A v4-only full tunnel (a WireGuard config whose AllowedIPs is 0.0.0.0/0 alone): Android adds `::/0 unreachable` so
// no app's IPv6 leaks around it (Vpn.makeLinkProperties). The daemon's IPv6 must fail closed in the tunnel too.
const sampleDumpsysVpnV4Only = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.4.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{110} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun4 ` +
	`LinkAddresses: [ 10.66.0.2/32 ] DnsAddresses: [ /10.66.0.1 ] Domains: null MTU: 1420 ` +
	`Routes: [ 0.0.0.0/0 -> 0.0.0.0 tun4 mtu 0,::/0 unreachable mtu 0 ] }}`

// A v6-only SPLIT tunnel: one ULA route, IPv4 blocked by Android. Blocking IPv4 does not make it full.
const sampleDumpsysVpnV6Split = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53,/198.51.100.53 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.4.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{111} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun7 ` +
	`LinkAddresses: [ fd00:c0::2/128 ] DnsAddresses: [ ] Domains: null MTU: 1400 ` +
	`Routes: [ fd00:c0::/32 -> :: tun7 mtu 0,0.0.0.0/0 unreachable mtu 0 ] }}`

// The Tailscale exit-node layout with its DnsAddresses emptied -- a full tunnel naming no resolvers of its own: the
// public fallback resolvers are asked THROUGH it. The physical network's are its router's or its operator's, which
// may not answer through the tunnel, and asking them outside it would leak the lookups.
var sampleDumpsysVpnFullNoDNS = strings.Replace(sampleDumpsysVpnFull,
	"DnsAddresses: [ /100.100.100.100,/fd7a:115c:a1e0::53 ]", "DnsAddresses: [ ]", 1)

// WireGuard's "Exclude private IPs" full tunnel with no DNS line. WireGuard allowFamily()s both families unless its
// one peer routes a default (read from the bundled WireGuard.apk's GoBackend, not observed), so Android adds no
// family-wide block: IPv6 matches no route and goes physical, and the IPv6 public resolvers, which the tunnel does
// not route, are left out.
var sampleDumpsysVpnWGNoDNS = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}} ` +
	`NetworkAgentInfo{network{112} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun8 ` +
	`LinkAddresses: [ 10.70.0.2/32 ] DnsAddresses: [ ] Domains: null MTU: 1420 Routes: [ ` + wgRoutes + ` ] }}`

// The v4-only full tunnel naming no resolvers, with the IPv4 public fallbacks thrown out of it (its IPv6 is blocked
// by Android): it routes none of the four, so all four are used; with one thrown, the other IPv4 fallback is used.
var sampleDumpsysVpnV4AllThrown = strings.Replace(strings.Replace(sampleDumpsysVpnV4Only, "DnsAddresses: [ /10.66.0.1 ]",
	"DnsAddresses: [ ]", 1), "0.0.0.0/0 -> 0.0.0.0 tun4 mtu 0,", "0.0.0.0/0 -> 0.0.0.0 tun4 mtu 0,1.1.1.1/32 throw mtu 0,8.8.8.8/32 throw mtu 0,", 1)
var sampleDumpsysVpnV4OneThrown = strings.Replace(sampleDumpsysVpnV4AllThrown, "1.1.1.1/32 throw mtu 0,", "", 1)

// The IKEv2 session-lost VPN in the user-switch window: no default network line, and the Wi-Fi listed after it. Its
// resolver may answer only through the tunnel, which is down: it must not be adopted from the all-networks tier.
const sampleDumpsysVpnIKEv2LostWindow = `NetworkAgentInfo{network{130} ni{VPN CONNECTED/CONNECTED} lp{{LinkAddresses: [ ] ` +
	`DnsAddresses: [ /10.0.0.53 ] Domains: corp.example MTU: 1400 Routes: [ 0.0.0.0/0 unreachable mtu 0,::/0 unreachable mtu 0 ] }} ` +
	`NetworkAgentInfo{network{131} lp{{InterfaceName: wlan0 DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1500 ` +
	`Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}}`

// The switch window as a device lists it: the Wi-Fi (older, lower netId) BEFORE the session VPN, no default line.
// The VPN's own resolvers are excluded by reading ITS block, not the dump's first DnsAddresses.
var sampleDumpsysPhysicalFirstWindow = `NetworkAgentInfo{network{100} lp{{InterfaceName: wlan0 DnsAddresses: [ /192.168.1.1 ] ` +
	`Domains: null MTU: 1500 Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}} ` +
	sampleDumpsysVpnSplit[strings.Index(sampleDumpsysVpnSplit, "NetworkAgentInfo{network{106}"):]

// A registered-but-dead tunnel (#219) alone in the switch window: its resolver must not be adopted either.
const sampleDumpsysVpnDeadWindow = `NetworkAgentInfo{network{110} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun4 ` +
	`LinkAddresses: [ 10.66.0.2/32 ] DnsAddresses: [ /10.66.0.1 ] Domains: null MTU: 1420 ` +
	`Routes: [ 0.0.0.0/0 -> 0.0.0.0 tun4 mtu 0 ] }}`

// An IKEv2 VPN in its session-lost window, as Vpn's handler leaves it: InterfaceName gone, every route turned
// `unreachable`, still CONNECTED -- and a newer network (Wi-Fi rejoining) listed after it, by ascending netId.
const sampleDumpsysVpnIKEv2Lost = `Active default network: 131
NetworkAgentInfo{network{130} ni{VPN CONNECTED/CONNECTED} lp{{LinkAddresses: [ ] DnsAddresses: [ /10.0.0.53 ] ` +
	`Domains: corp.example MTU: 1400 Routes: [ 0.0.0.0/0 unreachable mtu 0,::/0 unreachable mtu 0 ] }} ` +
	`NetworkAgentInfo{network{131} lp{{InterfaceName: wlan0 DnsAddresses: [ /192.168.1.1 ] Domains: null MTU: 1500 ` +
	`Routes: [ 0.0.0.0/0 -> 192.168.1.1 wlan0 mtu 0 ]}}`

// The split fixture's physical network alone: the VPN has gone.
var sampleDumpsysPhysicalOnly = sampleDumpsysVpnSplit[:strings.Index(sampleDumpsysVpnSplit, "NetworkAgentInfo{network{106}")]

// What dumpsysConnectivity returns when the read fails: "" (it keeps stdout only, and dumpsys prints "Can't find
// service" to stderr). The service's own refusal does reach stdout, and describes no network either.
const sampleDumpsysFailed = ""
const sampleDumpsysDenied = "Permission Denial: can't dump ConnectivityService from from pid=4242, uid=1000 due to missing android.permission.DUMP permission\n"

// A VPN whose Routes field is missing: nothing can be shown to ride it.
const sampleDumpsysVpnNoRoutes = `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 DnsAddresses: [ /192.0.2.53 ] Domains: null MTU: 1500}} ` +
	`NetworkAgentInfo{network{108} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun3 ` +
	`LinkAddresses: [ 10.8.0.2/32 ] DnsAddresses: [ /10.8.0.1 ] Domains: null MTU: 1400 }}`

// The same VPN in the user-switch window: nothing else is described, so only the all-networks tier could find its
// resolver -- which an unreadable VPN must not contribute either.
var sampleDumpsysVpnNoRoutesNoDefault = sampleDumpsysVpnNoRoutes[strings.Index(sampleDumpsysVpnNoRoutes, "NetworkAgentInfo{network{108}"):]

// wgRoutes is that set as a VPN block's route entries.
var wgRoutes = strings.Join(strings.Split(wireguardExcludePrivate, ","), " -> 0.0.0.0 tun8 mtu 0,") + " -> 0.0.0.0 tun8 mtu 0"

// WireGuard's "Exclude private IPs" route set, read from the IPV4_PUBLIC_NETWORKS table in the classes.dex of the
// WireGuard.apk this repo bundles (core/vendor-common/prebuilts): thirty prefixes covering public IPv4 with no
// default route and no /1 halves.
const wireguardExcludePrivate = "0.0.0.0/5,8.0.0.0/7,11.0.0.0/8,12.0.0.0/6,16.0.0.0/4,32.0.0.0/3,64.0.0.0/2," +
	"128.0.0.0/3,160.0.0.0/5,168.0.0.0/6,172.0.0.0/12,172.32.0.0/11,172.64.0.0/10,172.128.0.0/9,173.0.0.0/8," +
	"174.0.0.0/7,176.0.0.0/4,192.0.0.0/9,192.128.0.0/11,192.160.0.0/13,192.169.0.0/16,192.170.0.0/15," +
	"192.172.0.0/14,192.176.0.0/12,192.192.0.0/10,193.0.0.0/8,194.0.0.0/7,196.0.0.0/6,200.0.0.0/5,208.0.0.0/4"

func routesOf(list string) []vpnRoute {
	var parts []string
	for _, pf := range strings.Split(list, ",") {
		pf = strings.TrimSpace(pf)
		if strings.HasSuffix(pf, "!") {
			parts = append(parts, strings.TrimSuffix(pf, "!")+" throw mtu 0")
		} else if strings.HasSuffix(pf, "?") {
			parts = append(parts, strings.TrimSuffix(pf, "?")+" unreachable mtu 0")
		} else {
			parts = append(parts, pf+" -> 0.0.0.0 tun0 mtu 0")
		}
	}
	return parseVpnRoutes("lp{{InterfaceName: tun0 Routes: [ " + strings.Join(parts, ",") + " ] }}")
}

// egressOf is the session VPN refreshNet would keep for these routes, full or not.
func egressOf(iface string, routes []vpnRoute) vpnEgress {
	return vpnEgress{iface: iface, routes: routes, full: vpnFullInIntent(routes)}
}

// vpnFullInIntent: at most one /8 of public IPv4 left to the physical network by the tunnel's own `->` routes, or a
// v6-only full tunnel. ("x!" is a throw carve-out, "x?" an unreachable block, which is never coverage.)
func TestVpnPublicGapFullInIntent(t *testing.T) {
	for _, tc := range []struct {
		name   string
		routes []vpnRoute
		want   bool
	}{
		{"split: tailnet hosts only (the lynx layout)", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnSplit)), false},
		{"full: an exit node adds the defaults", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnFull)), true},
		{"the /1 halves", routesOf("0.0.0.0/1,128.0.0.0/1"), true},
		{"one /1 half", routesOf("0.0.0.0/1"), false},
		{"WireGuard exclude-private-IPs (thirty prefixes, no default)", routesOf(wireguardExcludePrivate), true},
		{"shadowsocks-style bypass: default minus the LAN and two public /24s", routesOf("0.0.0.0/0,10.0.0.0/8!,192.168.0.0/16!,112.124.47.0/24!,114.114.114.0/24!"), true},
		{"default minus every non-public range", routesOf("0.0.0.0/0,0.0.0.0/8!,100.64.0.0/10!,127.0.0.0/8!,169.254.0.0/16!,192.0.0.0/24!,192.0.2.0/24!,192.88.99.0/24!,198.18.0.0/15!,198.51.100.0/24!,203.0.113.0/24!,224.0.0.0/3!"), true},
		{"default minus exactly one public /8 (the threshold)", routesOf("0.0.0.0/0,8.0.0.0/8!"), true},
		{"default minus a public /8 and one more address", routesOf("0.0.0.0/0,8.0.0.0/8!,9.9.9.9/32!"), false},
		{"default minus a public /7", routesOf("0.0.0.0/0,8.0.0.0/7!"), false},
		{"default minus a public /7 blocked: a block is not coverage", routesOf("0.0.0.0/0,8.0.0.0/7?"), false},
		{"v4-only full: IPv4 routed, IPv6 blocked by Android", routesOf("0.0.0.0/0,::/0?"), true},
		{"v4-only split: 10/8 routed, IPv6 blocked by Android", routesOf("10.0.0.0/8,::/0?"), false},
		{"v6-only full: ::/0 routed, IPv4 blocked by Android", routesOf("::/0,0.0.0.0/0?"), true},
		{"v6-only full by 2000::/3", routesOf("2000::/3,0.0.0.0/0?"), true},
		{"v6-only full: OpenVPN's redirect-gateway ipv6 (::/3, 2000::/4, 3000::/4, fc00::/7)", routesOf("::/3,2000::/4,3000::/4,fc00::/7,0.0.0.0/0?"), true},
		{"v6-only full by the two /4 halves alone", routesOf("2000::/4,3000::/4,0.0.0.0/0?"), true},
		{"v6-only full by the ::/1 halves", routesOf("::/1,8000::/1,0.0.0.0/0?"), true},
		{"v6-only full with a carve-out within the allowance", routesOf("::/0,2600::/12!,0.0.0.0/0?"), true},
		{"v6-only: a carve-out over the allowance", routesOf("::/0,2000::/8!,0.0.0.0/0?"), false},
		{"v6-only: exactly 1/256 of global unicast carved out (the threshold)", routesOf("::/0,2000::/11!,0.0.0.0/0?"), true},
		{"v6-only: the threshold and one more address", routesOf("::/0,2000::/11!,2020::/128!,0.0.0.0/0?"), false},
		{"v6-only: an IPv6 block is not coverage", routesOf("::/0,2000::/4?,0.0.0.0/0?"), false},
		{"v6-only: one /4 half is not full", routesOf("2000::/4,0.0.0.0/0?"), false},
		{"v6-only: 2000::/16 is not all of global unicast", routesOf("2000::/16,0.0.0.0/0?"), false},
		{"v6-only: a /1 outside global unicast", routesOf("8000::/1,0.0.0.0/0?"), false},
		{"v6-only: a route and a block at one prefix, the block wins", routesOf("::/0,::/0?,0.0.0.0/0?"), false},
		{"the same v6 tie, block listed first", routesOf("::/0?,::/0,0.0.0.0/0?"), false},
		{"v6-only split: one ULA routed, IPv4 blocked by Android", routesOf("fd00:c0::/32,0.0.0.0/0?"), false},
		{"v6-only split: public IPv6 in part only", routesOf("2600::/12,0.0.0.0/0?"), false},
		{"blocks alone carry nothing", routesOf("0.0.0.0/0?,::/0?"), false},
		{"IPv6 default alone strands IPv4", routesOf("::/0,fd00::/8"), false},
		{"a throw default carries nothing", routesOf("0.0.0.0/0!"), false},
		{"route and carve-out at the same prefix: the carve-out wins", routesOf("0.0.0.0/0,0.0.0.0/0!"), false},
		{"the same tie, carve-out listed first", routesOf("0.0.0.0/0!,0.0.0.0/0"), false},
		{"route and block at the same prefix: the block wins", routesOf("0.0.0.0/0,0.0.0.0/0?"), false},
		{"the same tie, block listed first", routesOf("0.0.0.0/0?,0.0.0.0/0"), false},
		{"no routes", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := vpnFullInIntent(tc.routes); got != tc.want {
				t.Fatalf("full-in-intent = %v (v4 gap %d, v6 gap %s), want %v", got, vpnPublicGap(tc.routes), vpnPublicGap6(tc.routes), tc.want)
			}
		})
	}
	if n := len(parseVpnRoutes("lp{{InterfaceName: tun0 MTU: 1280}}")); n != 0 {
		t.Fatalf("no Routes field parsed %d routes", n)
	}
	// Every non-public range is pinned on its own: carving it out of a default route leaves NO public gap, while
	// carving out the public address just past its end does (the threshold alone could not tell them apart).
	// The expected list is written out here, independently of ipv4NotPublic, and must equal it exactly: dropping an
	// entry there fails, and so does adding one this test does not pin.
	notPublic := []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
		"172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15",
		"198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3"}
	var want []ipv4Prefix
	for _, cidr := range notPublic {
		_, n0, _ := net.ParseCIDR(cidr)
		ones, _ := n0.Mask.Size()
		want = append(want, ipv4Prefix{start: ipv4Uint(n0.IP.To4()), bits: ones})
	}
	if !reflect.DeepEqual(ipv4NotPublic, want) {
		t.Fatalf("ipv4NotPublic = %v, want exactly the %d ranges pinned here", ipv4NotPublic, len(want))
	}
	for _, cidr := range notPublic {
		if g := vpnPublicGap(routesOf("0.0.0.0/0," + cidr + "!")); g != 0 {
			t.Errorf("carving out the non-public %s left a public gap of %d", cidr, g)
		}
		_, n0, _ := net.ParseCIDR(cidr)
		ones, _ := n0.Mask.Size()
		r := ipv4Prefix{start: ipv4Uint(n0.IP.To4()), bits: ones}
		next := uint64(r.start) + r.size()
		if next >= 1<<32 || ipv4InAny(uint32(next), ipv4NotPublic) {
			continue
		}
		n := uint32(next)
		one := fmt.Sprintf("%d.%d.%d.%d/32", n>>24, n>>16&0xff, n>>8&0xff, n&0xff)
		if g := vpnPublicGap(routesOf("0.0.0.0/0," + one + "!")); g != 1 {
			t.Errorf("carving out the public %s (just past %s) left a gap of %d, want 1", one, cidr, g)
		}
	}
}

// vpnEgress.takes: a connection rides the tunnel when its destination's longest-prefix match is a route into it, or
// an `unreachable` block in a tunnel that is full in intent (it then fails closed there); a block in a split tunnel,
// a `throw` carve-out, or no match, stays physical.
func TestVpnTakesPerDestination(t *testing.T) {
	split := egressOf("tun1", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnSplit)))
	wg := egressOf("tun0", routesOf(wireguardExcludePrivate))
	carve := egressOf("tun0", routesOf("0.0.0.0/0,8.8.8.0/24!,8.8.8.8/32"))
	v4only := egressOf("tun4", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnV4Only)))
	corp := egressOf("tun5", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnCorp)))
	v6split := egressOf("tun7", parseVpnRoutes(vpnNetworkBlock(sampleDumpsysVpnV6Split)))
	v6full := egressOf("tun6", routesOf("::/0,0.0.0.0/0?"))
	fullTie := egressOf("tun0", routesOf("0.0.0.0/0,8.8.8.0/24!,8.8.8.0/24?"))
	fullTieRev := egressOf("tun0", routesOf("0.0.0.0/0,8.8.8.0/24?,8.8.8.0/24!"))
	// The public destinations are Quad9's anycast resolvers, 9.9.9.9 and 149.112.112.112: public unicast, not a
	// Nowhere host, and not one of the fallback resolvers (publicFallbackDNS) that fixtures here throw out of a
	// tunnel. A documentation net (RFC 5737) cannot stand in for them: ipv4NotPublic counts all three as not public,
	// so a tunnel that sent only public IPv4 out the physical network would still pass with them.
	for _, tc := range []struct {
		name string
		v    vpnEgress
		ip   string
		want bool
	}{
		{"split: a public host goes physical", split, "9.9.9.9", false},
		{"split: a tailnet host rides", split, "100.64.0.20", true},
		{"split: a tailnet IPv6 resolver rides", split, "fd7a:115c:a1e0::53", true},
		{"WireGuard exclude-private: a public address rides", wg, "149.112.112.112", true},
		{"WireGuard exclude-private: the LAN stays physical", wg, "192.168.4.1", false},
		{"carve-out: a public /24 thrown out goes physical", carve, "8.8.8.4", false},
		{"carve-out: a more specific route inside it rides again", carve, "8.8.8.8", true},
		{"carve-out: everything else rides", carve, "1.1.1.1", true},
		{"route and carve-out at the same prefix: the carve-out wins", egressOf("tun0", routesOf("0.0.0.0/0,0.0.0.0/0!")), "1.1.1.1", false},
		{"the same tie, carve-out listed first", egressOf("tun0", routesOf("0.0.0.0/0!,0.0.0.0/0")), "1.1.1.1", false},
		{"full tunnel: carve-out and block at one prefix, the block wins", fullTie, "8.8.8.8", true},
		{"the same tie, block listed first", fullTieRev, "8.8.8.8", true},
		{"v4-only full tunnel: IPv4 rides", v4only, "9.9.9.9", true},
		{"v4-only full tunnel: IPv6 is blocked in it, and stays there", v4only, "2606:4700:4700::1111", true},
		{"v4-only split tunnel: its hosts ride", corp, "10.1.2.3", true},
		{"v4-only split tunnel: Android's IPv6 block does not pull IPv6 in", corp, "2606:4700:4700::1111", false},
		{"v4-only split tunnel: nor a NAT64 address", corp, "64:ff9b::909:909", false},
		{"v6-only split tunnel: its hosts ride", v6split, "fd00:c0::1", true},
		{"v6-only split tunnel: IPv4 goes physical", v6split, "9.9.9.9", false},
		{"v6-only full tunnel: IPv6 rides", v6full, "2606:4700:4700::1111", true},
		{"v6-only full tunnel: IPv4 is blocked in it, and stays there", v6full, "9.9.9.9", true},
		{"no routes take nothing", vpnEgress{iface: "tun0"}, "1.1.1.1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.v.takes(net.ParseIP(tc.ip)); got != tc.want {
				t.Fatalf("takes(%s) = %v, want %v", tc.ip, got, tc.want)
			}
		})
	}
}

// refreshNet keeps the physical interface as the bind default and the VPN apart; egressFor then picks per
// connection, DNS rides the VPN's resolvers only for a full tunnel, and every resolver dial is bound by where its
// list came from (dnsEgress), never by its destination. The tun cannot exist on a test host, so the usability seam
// holds it up; everything else is the real decision.
func TestRefreshNetSplitsByDestination(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	usable := true
	vpnIfaceUsable = func(string) bool { return usable }
	state := func() (string, []string, bool) {
		netMu.Lock()
		defer netMu.Unlock()
		return netIface, append([]string(nil), dnsServers...), dnsFromVPN
	}
	// The physical network's own resolvers are documentation addresses (RFC 5737). Unlike the public destinations
	// (the Quad9 addresses TestVpnTakesPerDestination explains), that costs nothing: no route decision reads a
	// network's own resolver address, because a resolver dial is bound by its list's provenance.
	physical := []string{"192.0.2.53:53", "198.51.100.53:53"}
	vpnDNS := []string{"100.100.100.100:53", "[fd7a:115c:a1e0::53]:53"}
	// wantDNS nil = the list is checked by the caller; wantDNSIface is where every resolver dial is bound.
	step := func(name, dump, wantIface string, wantDNS []string, wantFromVPN bool, wantDNSIface string, egress map[string]string) {
		t.Helper()
		dumpsysConnectivity = func() string { return dump }
		refreshNet(false)
		iface, dns, fromVPN := state()
		if iface != wantIface || (wantDNS != nil && !reflect.DeepEqual(dns, wantDNS)) || fromVPN != wantFromVPN {
			t.Fatalf("%s: iface=%q dns=%v fromVPN=%v, want %q %v %v", name, iface, dns, fromVPN, wantIface, wantDNS, wantFromVPN)
		}
		if got := dnsEgress(); got != wantDNSIface {
			t.Fatalf("%s: resolver dials bound to %q, want %q", name, got, wantDNSIface)
		}
		for addr, want := range egress {
			if got := egressFor(addr); got != want {
				t.Fatalf("%s: egressFor(%s) = %q, want %q", name, addr, got, want)
			}
		}
	}
	step("split", sampleDumpsysVpnSplit, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "100.64.0.20:443": "tun1", "[fd7a:115c:a1e0::53]:53": "tun1"})
	step("full (exit node on)", sampleDumpsysVpnFull, "wlan0", vpnDNS, true, "tun1",
		map[string]string{"9.9.9.9:443": "tun1", "149.112.112.112:443": "tun1", "[fe80::1%wlan0]:53": "wlan0"})
	step("split again (exit node off)", sampleDumpsysVpnSplit, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	// A failed read under a split tunnel keeps it split: the physical list stays physical, the tunnel its own hosts.
	step("a failed read under a split tunnel", sampleDumpsysFailed, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "100.64.0.20:443": "tun1"})

	// Full again, then the exit node goes off INSIDE the switch window: no default network, and the union tier sees
	// only the VPN's own resolvers. They must not be adopted, the bind default stays the physical wlan0, and a
	// public destination does not ride the tunnel.
	step("full, before the window", sampleDumpsysVpnFull, "wlan0", vpnDNS, true, "tun1", nil)
	step("split in the switch window", sampleDumpsysVpnSplitNoDefault, "wlan0", nil, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	if _, dns, _ := state(); len(dns) == 0 {
		t.Fatal("switch window: no resolver at all")
	} else {
		for _, d := range dns {
			if strings.HasPrefix(d, "100.100.100.100:") || strings.Contains(d, "fd7a:115c:a1e0::53") {
				t.Fatalf("split tunnel in the switch window adopted the VPN's own resolver: dns=%v", dns)
			}
		}
	}

	// A split VPN sharing its resolver's address with the physical network: the physical resolver is still used, and
	// its lookups leave on wlan0 although the VPN routes that address -- a resolver dial is bound by where its list
	// came from. Any other connection to that address still follows the VPN's route.
	step("split, shared resolver address", sampleDumpsysVpnSplitSharedDNS, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "192.168.1.1:443": "tun2"})
	// A corporate split VPN routing all of RFC 1918 over a home Wi-Fi: the same, with its own resolver kept out.
	step("corporate split over a home LAN", sampleDumpsysVpnCorp, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "10.1.2.3:443": "tun5", "192.168.1.1:443": "tun5",
			"[2606:4700:4700::1111]:443": "wlan0"})
	// A v6-only split tunnel: Android's IPv4 block does not make it full, so IPv4 and the lookups stay physical.
	step("v6-only split", sampleDumpsysVpnV6Split, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "[fd00:c0::1]:443": "tun7"})

	// A v4-only full tunnel: IPv6 is blocked in it, so an IPv6 destination is bound to the tun and fails closed there
	// instead of leaving on the physical network the VPN forbids it.
	step("v4-only full tunnel", sampleDumpsysVpnV4Only, "wlan0", []string{"10.66.0.1:53"}, true, "tun4",
		map[string]string{"9.9.9.9:443": "tun4", "[2606:4700:4700::1111]:443": "tun4"})
	// A failed read describes no network at all, which is not evidence the tunnel went: everything is kept -- the
	// tunnel, its resolvers, and where both are bound.
	step("a failed read under a full tunnel", sampleDumpsysFailed, "wlan0", []string{"10.66.0.1:53"}, true, "tun4",
		map[string]string{"9.9.9.9:443": "tun4", "[2606:4700:4700::1111]:443": "tun4"})
	step("a refused read under a full tunnel", sampleDumpsysDenied, "wlan0", []string{"10.66.0.1:53"}, true, "tun4",
		map[string]string{"9.9.9.9:443": "tun4"})
	// The tun stops being usable (#219's shape): nothing is sent into it, and the physical resolvers return.
	usable = false
	step("the tun is not usable", sampleDumpsysVpnV4Only, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "[2606:4700:4700::1111]:443": "wlan0"})
	usable = true
	// A full tunnel naming no resolvers: the public fallback resolvers, asked through the tunnel -- those it routes.
	step("full tunnel, no resolvers of its own", sampleDumpsysVpnFullNoDNS, "wlan0", fallbackAddrs(), true, "tun1",
		map[string]string{"9.9.9.9:443": "tun1"})
	step("WireGuard exclude-private, no DNS line", sampleDumpsysVpnWGNoDNS, "wlan0", []string{"1.1.1.1:53", "8.8.8.8:53"}, true, "tun8",
		map[string]string{"9.9.9.9:443": "tun8", "192.168.1.1:53": "wlan0", "[2606:4700:4700::1111]:443": "wlan0"})
	// The fallbacks the tunnel does not route are left out; if it routes none of them, all of them are used.
	step("full tunnel, no resolvers, one IPv4 fallback thrown", sampleDumpsysVpnV4OneThrown, "wlan0", []string{"1.1.1.1:53"}, true, "tun4",
		map[string]string{"9.9.9.9:443": "tun4", "8.8.8.8:53": "wlan0"})
	step("full tunnel, no resolvers, both IPv4 fallbacks thrown (IPv6 blocked)", sampleDumpsysVpnV4AllThrown, "wlan0", fallbackAddrs(), true, "tun4",
		map[string]string{"9.9.9.9:443": "tun4"})
	// An IKEv2 VPN reconnecting has no interface, so it is no VPN: nothing rides it, and the newer network listed
	// after it is not mistaken for its tunnel.
	step("an IKEv2 VPN in its session-lost window", sampleDumpsysVpnIKEv2Lost, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	netMu.Lock()
	lost := vpnEg
	netMu.Unlock()
	if lost.iface != "" {
		t.Fatalf("an IKEv2 VPN with no interface was kept as a VPN on %q (the next network's interface)", lost.iface)
	}
	// A VPN's own resolvers stay out of the all-networks tier, in memory and in the fork cache, whether the VPN is
	// declined (an IKEv2 one with no interface, a dead tunnel -- #219) or kept but split (listed after the Wi-Fi). The
	// cache is read after EACH step: a step that publishes nothing leaves the previous step's file in place.
	noVPNResolverCached := func(name string) {
		t.Helper()
		cached, _, _, _, _, _ := readDNSCache()
		if len(cached) == 0 {
			t.Fatalf("%s: the fork cache holds no list", name)
		}
		for _, c := range cached {
			if strings.HasPrefix(c, "10.0.0.53:") || strings.HasPrefix(c, "10.66.0.1:") || strings.HasPrefix(c, "100.100.100.100:") {
				t.Fatalf("%s: a VPN's own resolver was published to the fork cache: %v", name, cached)
			}
		}
	}
	step("an IKEv2 session loss in the switch window", sampleDumpsysVpnIKEv2LostWindow, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	noVPNResolverCached("an IKEv2 session loss in the switch window")
	step("the Wi-Fi listed before a split VPN in the switch window", sampleDumpsysPhysicalFirstWindow, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	noVPNResolverCached("the Wi-Fi listed before a split VPN in the switch window")
	usable = false
	step("a dead tunnel alone in the switch window", sampleDumpsysVpnDeadWindow, "wlan0", []string{"192.168.1.1:53"}, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	noVPNResolverCached("a dead tunnel alone in the switch window")
	usable = true
	// The VPN goes away altogether: its routes and its resolvers go with it.
	step("full again", sampleDumpsysVpnFull, "wlan0", vpnDNS, true, "tun1", nil)
	step("the VPN removed", sampleDumpsysPhysicalOnly, "wlan0", physical, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0", "100.64.0.20:443": "wlan0"})
	// A VPN whose routes cannot be read, in the switch window: its resolver is kept out of the all-networks tier.
	step("an unreadable VPN in the switch window", sampleDumpsysVpnNoRoutesNoDefault, "wlan0", nil, false, "wlan0",
		map[string]string{"9.9.9.9:443": "wlan0"})
	if _, dns, _ := state(); len(dns) == 0 {
		t.Fatal("unreadable VPN in the switch window: no resolver at all")
	} else {
		for _, d := range dns {
			if strings.HasPrefix(d, "10.8.0.1:") {
				t.Fatalf("an unreadable VPN's resolver was adopted in the switch window: dns=%v", dns)
			}
		}
	}
}

// The store, gateway and OTA dials -- http.DefaultTransport, whose DialContext init() wires to bindControl -- are
// bound per destination: into the tunnel exactly when the VPN takes the address. The bind is recorded, not performed,
// so the request still reaches the local test server.
func TestStoreDialsBindByDestination(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	vpnIfaceUsable = func(string) bool { return true }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok") }))
	defer srv.Close()
	var mu sync.Mutex
	var bound []string
	bindToIface = func(c syscall.RawConn, iface string) {
		mu.Lock()
		bound = append(bound, iface)
		mu.Unlock()
	}
	phys := `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: lo DnsAddresses: [ /127.0.0.1 ] Domains: null MTU: 65536 ` +
		`Routes: [ 0.0.0.0/0 -> 127.0.0.1 lo mtu 0 ]}} `
	vpn := func(routes string) string {
		return phys + `NetworkAgentInfo{network{140} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun9 ` +
			`LinkAddresses: [ 10.99.0.2/32 ] DnsAddresses: [ ] Domains: null MTU: 1400 Routes: [ ` + routes + ` ] }}`
	}
	for _, tc := range []struct{ name, dump, want string }{
		{"a split VPN routing the server's address", vpn("127.0.0.0/8 -> 0.0.0.0 tun9 mtu 0"), "tun9"},
		{"a split VPN not routing it", vpn("10.0.0.0/8 -> 0.0.0.0 tun9 mtu 0"), "lo"},
		{"a full tunnel", vpn("0.0.0.0/0 -> 0.0.0.0 tun9 mtu 0,::/0 -> :: tun9 mtu 0"), "tun9"},
	} {
		dump := tc.dump
		dumpsysConnectivity = func() string { return dump }
		refreshNet(true)
		mu.Lock()
		bound = nil
		mu.Unlock()
		tr := http.DefaultTransport.(*http.Transport).Clone() // init()'s DialContext, bindControl and all
		tr.DisableKeepAlives = true
		resp, err := (&http.Client{Transport: tr, Timeout: 5 * time.Second}).Get(srv.URL)
		if err != nil {
			t.Fatalf("%s: GET through the production transport: %v", tc.name, err)
		}
		resp.Body.Close()
		mu.Lock()
		got := append([]string(nil), bound...)
		mu.Unlock()
		if len(got) == 0 {
			t.Fatalf("%s: the production transport dialled without binding", tc.name)
		}
		for _, g := range got {
			if g != tc.want {
				t.Fatalf("%s: a store dial bound %q, want %q (all binds: %v)", tc.name, g, tc.want, got)
			}
		}
	}
}

// The production resolver's dials are bound by the list's provenance: setResolverDynamic's Dial closure runs
// dnsBindControl, which binds by dnsEgress -- not bindControl, which binds by destination. Two dumps tell them apart
// on the loopback resolver: under a split VPN that ROUTES 127.0.0.1 the dials must still bind the physical "lo", and
// under a full tunnel naming 127.0.0.1 as its resolver they must bind the tunnel. The bind itself is recorded, not
// performed (the tunnel does not exist on the test host), so the lookups still reach the fake server.
func TestResolverDialsBindByProvenance(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	vpnIfaceUsable = func(string) bool { return true }
	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
	plainAddr := plain.servePlain(t)
	_, plainPort, _ = net.SplitHostPort(plainAddr)
	var mu sync.Mutex
	var bound []string
	bindToIface = func(c syscall.RawConn, iface string) {
		mu.Lock()
		bound = append(bound, iface)
		mu.Unlock()
	}
	phys := `Active default network: 121
NetworkAgentInfo{network{121} lp{{InterfaceName: lo DnsAddresses: [ /127.0.0.1 ] Domains: null MTU: 65536 ` +
		`Routes: [ 0.0.0.0/0 -> 127.0.0.1 lo mtu 0 ]}} `
	vpn := func(routes, dns string) string {
		return phys + `NetworkAgentInfo{network{140} ni{VPN CONNECTED/CONNECTED} lp{{InterfaceName: tun9 ` +
			`LinkAddresses: [ 10.99.0.2/32 ] DnsAddresses: [ ` + dns + ` ] Domains: null MTU: 1400 Routes: [ ` + routes + ` ] }}`
	}
	setResolverDynamic()
	for _, tc := range []struct{ name, dump, want string }{
		{"a split VPN routing the resolver's address", vpn("127.0.0.0/8 -> 0.0.0.0 tun9 mtu 0", ""), "lo"},
		{"a full tunnel naming the resolver", vpn("0.0.0.0/0 -> 0.0.0.0 tun9 mtu 0,::/0 -> :: tun9 mtu 0", "/127.0.0.1"), "tun9"},
	} {
		dump := tc.dump
		dumpsysConnectivity = func() string { return dump }
		refreshNet(true)
		if got := egressFor(plainAddr); tc.want == "lo" && got != "tun9" {
			t.Fatalf("%s: the fixture no longer separates the rules (egressFor(%s) = %q)", tc.name, plainAddr, got)
		}
		mu.Lock()
		bound = nil
		mu.Unlock()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		ips, err := net.DefaultResolver.LookupIPAddr(ctx, "store.example")
		cancel()
		if err != nil || len(ips) != 1 || !ips[0].IP.Equal(storeIP) {
			t.Fatalf("%s: lookup through the production resolver = %v, %v", tc.name, ips, err)
		}
		mu.Lock()
		got := append([]string(nil), bound...)
		mu.Unlock()
		if len(got) == 0 {
			t.Fatalf("%s: the production resolver dialled without binding", tc.name)
		}
		for _, g := range got {
			if g != tc.want {
				t.Fatalf("%s: a resolver dial bound %q, want %q (all binds: %v)", tc.name, g, tc.want, got)
			}
		}
	}
}

// The VPN classification line is change-only, and an unreadable route list gets its own line, not "split".
func TestVpnStateLineIsChangeOnly(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	vpnIfaceUsable = func(string) bool { return true }
	capture := func(dumps ...string) string {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		orig := os.Stderr
		os.Stderr = w
		for _, d := range dumps {
			d := d
			dumpsysConnectivity = func() string { return d }
			refreshNet(false)
		}
		os.Stderr = orig
		w.Close()
		out, _ := io.ReadAll(r)
		return string(out)
	}
	out := capture(sampleDumpsysVpnSplit, sampleDumpsysVpnSplit, sampleDumpsysVpnSplit)
	if n := strings.Count(out, "(a split tunnel)"); n != 1 {
		t.Fatalf("split line logged %d times over three identical refreshes, want 1:\n%s", n, out)
	}
	out = capture(sampleDumpsysVpnFull, sampleDumpsysVpnSplit)
	if strings.Count(out, "is a full tunnel") != 1 || strings.Count(out, "(a split tunnel)") != 1 {
		t.Fatalf("split -> full -> split must log each change once:\n%s", out)
	}
	out = capture(sampleDumpsysVpnFull, sampleDumpsysFailed, sampleDumpsysDenied, sampleDumpsysVpnFull)
	if n := strings.Count(out, "is a full tunnel"); n != 1 {
		t.Fatalf("failed reads between two identical full refreshes must change nothing, so log nothing; got %d full lines:\n%s", n, out)
	}
	// From a FULL tunnel -- where a public destination rides the tun -- so the check below proves the unreadable
	// route list cleared it.
	out = capture(sampleDumpsysVpnNoRoutes)
	if !strings.Contains(out, "routes are unreadable") || strings.Contains(out, "(a split tunnel)") {
		t.Fatalf("a VPN with no Routes field must log its own line, not split:\n%s", out)
	}
	if got := egressFor("9.9.9.9:443"); got != "wlan0" {
		t.Fatalf("unreadable routes: egressFor = %q, want wlan0", got)
	}
	if got := dnsEgress(); got != "wlan0" {
		t.Fatalf("unreadable routes: resolver dials bound to %q, want wlan0", got)
	}
	// A VPN that goes away and comes back the same is a change each way, so it is logged again.
	if out = capture(sampleDumpsysVpnSplit); strings.Count(out, "(a split tunnel)") != 1 {
		t.Fatalf("unreadable -> split must log split once:\n%s", out)
	}
	if out = capture(sampleDumpsysPhysicalOnly, sampleDumpsysVpnSplit); strings.Count(out, "(a split tunnel)") != 1 {
		t.Fatalf("split -> no VPN -> split must log split again:\n%s", out)
	}
	// Public resolvers asked through a full tunnel that names none are labelled so, not as a discovered list.
	if out = capture(sampleDumpsysVpnFullNoDNS); !strings.Contains(out, "src=PUBLIC-VIA-TUNNEL") {
		t.Fatalf("a DNS-less full tunnel's public resolvers must be labelled PUBLIC-VIA-TUNNEL:\n%s", out)
	}
	if out = capture(sampleDumpsysVpnFull); !strings.Contains(out, "src=discovered") || strings.Contains(out, "PUBLIC-VIA-TUNNEL") {
		t.Fatalf("a full tunnel's own resolvers must be labelled discovered:\n%s", out)
	}
}

func TestParsePrivateDNS(t *testing.T) {
	for _, tc := range []struct {
		name  string
		block string
		want  privateDNS
	}{
		{"strict, validated (default block, not the cellular one listed first)", defaultNetworkBlock(sampleDumpsysStrict),
			privateDNS{Host: "dns.mullvad.net", Use: true, Validated: []string{"2a07:e340::2", "194.242.2.2"}}},
		{"strict, blocked: hostname but nothing validated", defaultNetworkBlock(sampleDumpsysStrictBlocked),
			privateDNS{Host: "dns.mullvad.net", Use: true}},
		{"opportunistic: no hostname", defaultNetworkBlock(sampleDumpsysOpportunistic),
			privateDNS{Use: true, Validated: []string{"192.0.2.53"}}},
		{"off", defaultNetworkBlock(sampleDumpsysPrivateOff), privateDNS{}},
		{"bounded to the default's own block", defaultNetworkBlock(sampleDumpsysScoped), privateDNS{}},
		{"VPN block carries its own posture", vpnNetworkBlock(sampleDumpsysVpnStrict),
			privateDNS{Host: "dns.mullvad.net", Use: true, Validated: []string{"194.242.2.2"}}},
		{"empty block", "", privateDNS{}},
		// an empty specifier prints "PrivateDnsServerName:" followed by the NEXT key -- that is not a host
		{"empty specifier is not a hostname", "lp{{DnsAddresses: [ /1.2.3.4 ] UsePrivateDns: true PrivateDnsServerName: Domains: null MTU: 1500}}",
			privateDNS{Use: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := parsePrivateDNS(tc.block); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("parsePrivateDNS = %+v, want %+v", got, tc.want)
			}
		})
	}
	// the block helpers themselves: absent marker / absent block / no VPN -> "" (unknown, never "off")
	if defaultNetworkBlock(sampleDumpsys) != "" {
		t.Error("no Active-default marker must yield no block")
	}
	if defaultNetworkBlock("Active default network: 999\n"+sampleDumpsysStrict) != "" {
		t.Error("a marker whose block is missing must yield no block")
	}
	if vpnNetworkBlock(sampleDumpsysStrict) != "" {
		t.Error("no VPN must yield no block")
	}
	// the strict block's own parsers still see its servers and interface -- the new fragments break nothing
	if got := parseDefaultNetworkDNS(sampleDumpsysStrict); !reflect.DeepEqual(got, []string{"2001:4860:4860::8844", "192.0.2.53", "198.51.100.53"}) {
		t.Errorf("parseDefaultNetworkDNS(strict) = %v", got)
	}
	if got := parseDefaultIface(sampleDumpsysStrict); got != "wlan0" {
		t.Errorf("parseDefaultIface(strict) = %q", got)
	}
}

// resetResolverState snapshots every resolver global a test touches and restores it on cleanup, so the DoT
// tests cannot leak posture, servers or the injected dump into the rest of the package.
func resetResolverState(t *testing.T) {
	t.Helper()
	netMu.Lock()
	sDNS, sIface, sAt, sGood, sVPN, sHost, sAddrs := dnsServers, netIface, netAt, dnsGoodAt, dnsFromVPN, dotHost, dotAddrs
	dnsServers, netIface, netAt, dnsGoodAt, dnsFromVPN, dotHost, dotAddrs = nil, "", time.Time{}, time.Time{}, false, "", nil
	sVpnEg, sVpnLogged := vpnEg, vpnStateLogged
	vpnEg, vpnStateLogged = vpnEgress{}, ""
	sEmpty, sSeed := dnsEmptySince, dnsSeedIface
	dnsEmptySince, dnsSeedIface = time.Time{}, ""
	netMu.Unlock()
	sUsable, sBind := vpnIfaceUsable, bindToIface
	dotMu.Lock()
	sBoot, sBootAt, sLog, sFlight := dotBoot, dotBootAt, dotLogAt, dotFlight
	dotBoot, dotBootAt, dotLogAt, dotFlight = map[string][]string{}, map[string]time.Time{}, map[string]time.Time{}, map[string]*dotBootstrap{}
	dotMu.Unlock()
	sDump, sPort, sPlain, sTLS, sResolver := dumpsysConnectivity, dotPort, plainPort, dotTLSConfig, net.DefaultResolver
	t.Cleanup(func() {
		netMu.Lock()
		dnsServers, netIface, netAt, dnsGoodAt, dnsFromVPN, dotHost, dotAddrs = sDNS, sIface, sAt, sGood, sVPN, sHost, sAddrs
		vpnEg, vpnStateLogged = sVpnEg, sVpnLogged
		dnsEmptySince, dnsSeedIface = sEmpty, sSeed
		netMu.Unlock()
		vpnIfaceUsable, bindToIface = sUsable, sBind
		dotMu.Lock()
		dotBoot, dotBootAt, dotLogAt, dotFlight = sBoot, sBootAt, sLog, sFlight
		dotMu.Unlock()
		dumpsysConnectivity, dotPort, plainPort, dotTLSConfig, net.DefaultResolver = sDump, sPort, sPlain, sTLS, sResolver
	})
}

func currentDoT() (string, []string) {
	netMu.Lock()
	defer netMu.Unlock()
	return dotHost, append([]string(nil), dotAddrs...)
}

// refreshNet adopts the posture from the dump: strict -> the host + the OS-validated endpoints (v4 first), the
// cache file carries it, the log line names the host; an ABSENT default block KEEPS the posture (the
// user-switch window must not read as "off"); a present block without the fragments turns it off; a strict
// block with nothing validated falls back to what this process already knows for the host.
func TestRefreshNetAdoptsPrivateDNS(t *testing.T) {
	resetResolverState(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)

	dumpsysConnectivity = func() string { return sampleDumpsysStrict }
	refreshNet(false)
	host, addrs := currentDoT()
	if host != "dns.mullvad.net" {
		t.Fatalf("dotHost = %q, want dns.mullvad.net", host)
	}
	if want := []string{"194.242.2.2:853", "[2a07:e340::2]:853"}; !reflect.DeepEqual(addrs, want) {
		t.Fatalf("dotAddrs = %v, want %v (OS-validated, v4 first)", addrs, want)
	}
	b, err := os.ReadFile(filepath.Join(dir, dnsCacheFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "\ndot dns.mullvad.net 194.242.2.2,2a07:e340::2\n") {
		t.Fatalf("cache file lacks the DoT line:\n%s", b)
	}
	if got, _, ok := loadDNSCache(); !ok || !reflect.DeepEqual(got, []string{"192.0.2.53:53", "198.51.100.53:53"}) {
		t.Fatalf("loadDNSCache must still return only the server lines, got %v ok=%v", got, ok)
	}
	if h, ips, ok := loadDoTCache(); !ok || h != "dns.mullvad.net" || !reflect.DeepEqual(ips, []string{"194.242.2.2", "2a07:e340::2"}) {
		t.Fatalf("loadDoTCache = %q %v %v", h, ips, ok)
	}
	if line := egressLine("wlan0", []string{"192.0.2.53:53"}, "discovered", host); !strings.HasSuffix(line, " dot=dns.mullvad.net") {
		t.Fatalf("egress line must name the DoT host: %q", line)
	}
	if line := egressLine("wlan0", nil, "discovered", ""); !strings.HasSuffix(line, " dot=off") {
		t.Fatalf("egress line must say dot=off when plain: %q", line)
	}

	// the switch window: no active default at all -> the posture is KEPT, not cleared
	dumpsysConnectivity = func() string { return sampleDumpsys }
	netMu.Lock()
	netAt = time.Time{}
	netMu.Unlock()
	refreshNet(false)
	if host, _ = currentDoT(); host != "dns.mullvad.net" {
		t.Fatalf("an absent default block cleared the posture (dotHost=%q); a transient must never become plaintext", host)
	}

	// a present block with no fragments: off
	dumpsysConnectivity = func() string { return sampleDumpsysPrivateOff }
	refreshNet(false)
	if host, addrs = currentDoT(); host != "" || len(addrs) != 0 {
		t.Fatalf("private DNS off, but dotHost=%q dotAddrs=%v", host, addrs)
	}

	// strict again, nothing validated this time: the endpoints come from what this process remembered
	dumpsysConnectivity = func() string { return sampleDumpsysStrictBlocked }
	refreshNet(false)
	if host, addrs = currentDoT(); host != "dns.mullvad.net" || !reflect.DeepEqual(addrs, []string{"194.242.2.2:853", "[2a07:e340::2]:853"}) {
		t.Fatalf("strict-without-validated: dotHost=%q dotAddrs=%v, want the remembered endpoints", host, addrs)
	}

	// a VPN that is adopted takes ITS block's posture -- through refreshNet itself (NWP-20260925-03 added the
	// usability seam, so a tun can be held up). This runs BEFORE the parse-side check below on purpose: that check
	// calls dotTargetFor on the VPN block, which REMEMBERS the VPN's endpoint, and a refresh that wrongly kept the
	// default network's posture would then fall back to that same remembered endpoint and pass. Here the
	// remembered endpoints are still the default network's two (v4 and v6), so only the VPN block yields v4 alone.
	vpnIfaceUsable = func(string) bool { return true }
	dumpsysConnectivity = func() string { return sampleDumpsysVpnStrict }
	refreshNet(false)
	if host, addrs = currentDoT(); host != "dns.mullvad.net" || !reflect.DeepEqual(addrs, []string{"194.242.2.2:853"}) {
		t.Fatalf("adopted full-tunnel VPN: dotHost=%q dotAddrs=%v, want the VPN block's own validated endpoint", host, addrs)
	}
	// the parse side on its own: the VPN block yields the VPN's own validated endpoint.
	if h, a := dotTargetFor(parsePrivateDNS(vpnNetworkBlock(sampleDumpsysVpnStrict))); h != "dns.mullvad.net" || !reflect.DeepEqual(a, []string{"194.242.2.2:853"}) {
		t.Fatalf("VPN block -> %q %v", h, a)
	}
}

// ---- a minimal DNS responder: UDP (plain) and TLS with 2-byte length framing (DoT) ----

type fakeDNS struct {
	mu   sync.Mutex
	seen map[string]int      // qname -> queries received
	zone map[string][]net.IP // qname -> A records
}

func newFakeDNS(zone map[string][]net.IP) *fakeDNS {
	return &fakeDNS{seen: map[string]int{}, zone: zone}
}

func (f *fakeDNS) count(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.seen[name]
}

func (f *fakeDNS) total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.seen {
		n += c
	}
	return n
}

// reply parses one query and builds the answer: A records from the zone, an empty NOERROR for AAAA, NXDOMAIN
// for a name outside the zone. nil when the query is unparsable.
func (f *fakeDNS) reply(msg []byte) []byte {
	if len(msg) < 12 || binary.BigEndian.Uint16(msg[4:6]) != 1 {
		return nil
	}
	i := 12
	var labels []string
	for {
		if i >= len(msg) {
			return nil
		}
		l := int(msg[i])
		i++
		if l == 0 {
			break
		}
		if l&0xC0 != 0 || i+l > len(msg) {
			return nil
		}
		labels = append(labels, string(msg[i:i+l]))
		i += l
	}
	if i+4 > len(msg) {
		return nil
	}
	qtype := binary.BigEndian.Uint16(msg[i : i+2])
	qend := i + 4
	name := strings.ToLower(strings.Join(labels, "."))
	f.mu.Lock()
	f.seen[name]++
	ips, known := f.zone[name]
	f.mu.Unlock()

	resp := append([]byte{}, msg[0:2]...)
	if known {
		resp = append(resp, 0x81, 0x80) // QR RD RA, NOERROR
	} else {
		resp = append(resp, 0x81, 0x83) // NXDOMAIN
	}
	var ans []byte
	n := 0
	if known && qtype == 1 {
		for _, ip := range ips {
			if v4 := ip.To4(); v4 != nil {
				ans = append(ans, 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4)
				ans = append(ans, v4...)
				n++
			}
		}
	}
	resp = append(resp, 0, 1, byte(n>>8), byte(n), 0, 0, 0, 0)
	resp = append(resp, msg[12:qend]...)
	return append(resp, ans...)
}

// servePlain answers on a UDP socket at 127.0.0.1; returns host:port.
func (f *fakeDNS) servePlain(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 4096)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if r := f.reply(buf[:n]); r != nil {
				_, _ = pc.WriteTo(r, addr)
			}
		}
	}()
	return pc.LocalAddr().String()
}

// serveDoT answers over TLS with DNS-over-TCP framing at 127.0.0.1; returns host:port. A client that does not
// speak TLS cannot get an answer here, so every counted query provably arrived encrypted.
func (f *fakeDNS) serveDoT(t *testing.T, cert tls.Certificate) string {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					var hdr [2]byte
					if _, err := io.ReadFull(c, hdr[:]); err != nil {
						return
					}
					msg := make([]byte, binary.BigEndian.Uint16(hdr[:]))
					if _, err := io.ReadFull(c, msg); err != nil {
						return
					}
					r := f.reply(msg)
					if r == nil {
						return
					}
					out := append([]byte{byte(len(r) >> 8), byte(len(r))}, r...)
					if _, err := c.Write(out); err != nil {
						return
					}
				}
			}()
		}
	}()
	return ln.Addr().String()
}

// selfSignedDoT mints a throwaway certificate for name at 127.0.0.1 and installs it, through the test-only
// hook, as the ONLY root the resolver's DoT client trusts.
func selfSignedDoT(t *testing.T, name string) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: name},
		DNSNames:              []string{name},
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1)},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	dotTLSConfig = func(host string) *tls.Config {
		return &tls.Config{ServerName: host, RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}

// testResolver is net.DefaultResolver's Dial shape over a fixed target, without the production dial Control.
func testResolver(target func() dnsTarget) *net.Resolver {
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialDNS(ctx, network, target(), &net.Dialer{Timeout: 3 * time.Second})
		},
	}
}

var storeIP = net.IPv4(10, 0, 0, 1)

// A lookup in strict mode goes over TLS to the DoT host, and the plain servers see NOTHING.
func TestDoTRoundTrip(t *testing.T) {
	resetResolverState(t)
	cert := selfSignedDoT(t, "dot.test")
	dot := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
	dotAddr := dot.serveDoT(t, cert)
	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}, "dot.test": {net.IPv4(127, 0, 0, 1)}})
	plainAddr := plain.servePlain(t)

	r := testResolver(func() dnsTarget {
		return dnsTarget{plain: []string{plainAddr}, dot: "dot.test", dotAddrs: []string{dotAddr}}
	})
	ips, err := r.LookupIPAddr(context.Background(), "store.example")
	if err != nil {
		t.Fatalf("lookup over DoT: %v", err)
	}
	if len(ips) != 1 || !ips[0].IP.Equal(storeIP) {
		t.Fatalf("lookup = %v, want %v", ips, storeIP)
	}
	if dot.count("store.example") == 0 {
		t.Fatal("the DoT server never saw the query")
	}
	if n := plain.total(); n != 0 {
		t.Fatalf("the plain server saw %d query(ies); strict mode with known endpoints must send none", n)
	}
}

// Strict mode with an unreachable DoT endpoint FAILS the lookup. The plain server would answer -- and must
// never be asked: fail closed, exactly as the OS's own resolver does on a network that blocks 853.
func TestDoTStrictFailsClosed(t *testing.T) {
	resetResolverState(t)
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedAddr := closed.Addr().String()
	closed.Close() // nothing listens here any more
	_, port, _ := net.SplitHostPort(closedAddr)
	dotPort = port // so a re-bootstrap lands on the same dead endpoint, as a blocked 853 would

	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}, "dot.test": {net.IPv4(127, 0, 0, 1)}})
	plainAddr := plain.servePlain(t)

	r := testResolver(func() dnsTarget {
		return dnsTarget{plain: []string{plainAddr}, dot: "dot.test", dotAddrs: []string{closedAddr}}
	})
	ips, err := r.LookupIPAddr(context.Background(), "store.example")
	if err == nil {
		t.Fatalf("strict mode with a dead DoT endpoint answered %v -- that answer can only have come from plaintext", ips)
	}
	if !strings.Contains(err.Error(), "DoT dot.test unreachable") {
		t.Fatalf("error must name the DoT failure, got: %v", err)
	}
	if n := plain.count("store.example"); n != 0 {
		t.Fatalf("the plain server was asked for store.example %d time(s); strict mode must never downgrade", n)
	}
	// Go retries a failed lookup (attempts x A/AAAA); the re-bootstrap of the DoT host's own name must not
	// follow suit -- one plaintext round (an A and an AAAA) for the whole failed lookup, not one per retry.
	if n := plain.count("dot.test"); n > 2 {
		t.Fatalf("a single blocked lookup re-bootstrapped the DoT host %d times in plaintext; want one round", n)
	}
	if strings.Contains(err.Error(), "127.0.0.1") {
		t.Fatalf("the failure text carries an endpoint address, which login.log must not collect: %v", err)
	}
}

// The strict-mode failure text is address-free on EVERY path, not only the refused-dial one above. Review
// of this slice found two paths that passed Go's error text through verbatim: a TLS handshake that dies on
// the wire (a middlebox that accepts 853 and resets -- the text carried the DEVICE'S OWN ip:port on that
// network), and a failed bootstrap (Go's DNSError text carried the network's resolver address, the exact
// list backlog's dns=[...] row says login.log must not accumulate). dotUnreachable prints this text to
// login.log, which is durable and shipped in issue reports.
func TestDoTFailureTextIsAddressFree(t *testing.T) {
	assertNoAddr := func(t *testing.T, err error, addrs ...string) {
		t.Helper()
		if err == nil {
			t.Fatal("expected a strict-mode failure, got an answer")
		}
		if !strings.Contains(err.Error(), "DoT dot.test unreachable") {
			t.Fatalf("error must name the DoT failure, got: %v", err)
		}
		for _, a := range append(addrs, "127.0.0.1", "->") {
			if strings.Contains(err.Error(), a) {
				t.Fatalf("the failure text carries %q: %v", a, err)
			}
		}
	}

	t.Run("handshake reset by a middlebox", func(t *testing.T) {
		resetResolverState(t)
		t.Setenv("NOWHERE_STATE", "")
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ln.Close() })
		go func() { // accept, swallow the ClientHello, then RST -- what DPI on 853 looks like from the client
			for {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				_, _ = c.Read(make([]byte, 1))
				if tc, ok := c.(*net.TCPConn); ok {
					_ = tc.SetLinger(0)
				}
				c.Close()
			}
		}()
		plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
		plainAddr := plain.servePlain(t)
		r := testResolver(func() dnsTarget {
			return dnsTarget{plain: []string{plainAddr}, dot: "dot.test", dotAddrs: []string{ln.Addr().String()}}
		})
		_, err = r.LookupIPAddr(context.Background(), "store.example")
		assertNoAddr(t, err)
		if !strings.Contains(err.Error(), "tls: ") {
			t.Fatalf("the handshake failure must still say it was the handshake: %v", err)
		}
		if plain.count("store.example") != 0 {
			t.Fatal("the plain server was asked for the name; strict mode must never downgrade")
		}
	})

	// A bootstrap whose plain servers cannot even be dialled: the kinds come from dialPlain's typed failure.
	t.Run("bootstrap dial failure", func(t *testing.T) {
		resetResolverState(t)
		t.Setenv("NOWHERE_STATE", "")
		r := testResolver(func() dnsTarget {
			return dnsTarget{plain: []string{"[fe80::1]:53"}, dot: "dot.test"} // no zone -> connect fails
		})
		_, err := r.LookupIPAddr(context.Background(), "store.example")
		assertNoAddr(t, err, "fe80::1")
		if !strings.Contains(err.Error(), "bootstrap: ") {
			t.Fatalf("the failure must say it was the bootstrap: %v", err)
		}
	})

	// A bootstrap whose plain server is dialled but answers with ICMP port-unreachable: Go's resolver reports
	// the READ failure, whose text names both ends of the socket.
	t.Run("bootstrap read failure", func(t *testing.T) {
		resetResolverState(t)
		t.Setenv("NOWHERE_STATE", "")
		pc, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		dead := pc.LocalAddr().String()
		pc.Close() // nothing listens here any more
		r := testResolver(func() dnsTarget { return dnsTarget{plain: []string{dead}, dot: "dot.test"} })
		_, err = r.LookupIPAddr(context.Background(), "store.example")
		assertNoAddr(t, err)
		if !strings.Contains(err.Error(), "bootstrap: ") {
			t.Fatalf("the failure must say it was the bootstrap: %v", err)
		}
	})
}

// A DoT bootstrap under the PRODUCTION dialer's Control -- dnsBindControl since NWP-20260925-03, bindControl before
// it -- whose defaultNetIface refresh takes netMu, must complete. Review of this slice found a lock-order inversion
// here: dotEndpoints held dotMu across its plaintext lookup, whose dial ran bindControl -> defaultNetIface ->
// refreshNet -> dotTargetFor -> knownDoT -> dotMu, so a fresh process (netIface still "") deadlocked on its very
// first strict lookup until the context expired -- a spurious fail-closed on a working DoT network, with every
// other dial in the process parked on netMu behind it. The shipped tests dialled without bindControl and could not
// see it.
func TestDoTBootstrapUnderProductionControl(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", "")
	cert := selfSignedDoT(t, "dot.test")
	dot := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
	dotAddr := dot.serveDoT(t, cert)
	_, port, _ := net.SplitHostPort(dotAddr)
	dotPort = port
	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}, "dot.test": {net.IPv4(127, 0, 0, 1)}})
	plainAddr := plain.servePlain(t)
	// The dump the bootstrap's own dial-Control refresh reads: strict, nothing validated (so the bootstrap must
	// run), egress on the loopback so a bound socket still reaches the fake servers.
	dumpsysConnectivity = func() string { return strings.ReplaceAll(sampleDumpsysStrictBlocked, "wlan0", "lo") }

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	d := &net.Dialer{Timeout: 3 * time.Second, Control: dnsBindControl} // exactly setResolverDynamic's dialer
	start := time.Now()
	c, err := dialDNS(ctx, "udp", dnsTarget{plain: []string{plainAddr}, dot: "dot.test"}, d)
	if err != nil {
		t.Fatalf("strict dial under the production Control failed after %v: %v (a deadlock between dotMu and netMu shows as the context expiring)", time.Since(start), err)
	}
	c.Close()
	if plain.count("dot.test") == 0 {
		t.Fatal("the bootstrap never reached the plain server")
	}
	// and the process's other sockets are not parked behind the resolver
	done := make(chan string, 1)
	go func() { done <- defaultNetIface() }()
	select {
	case iface := <-done:
		if iface != "lo" {
			t.Fatalf("defaultNetIface = %q, want lo", iface)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("defaultNetIface blocked for 2s after the strict dial: netMu is still held")
	}
}

// The PRODUCTION resolver end to end -- setResolverDynamic's Dial closure, dnsBindControl, the posture parsed
// from the dump, the bootstrap through the discovered plain server -- with a concurrent refreshNet hammering
// netMu the way the netlink watcher does. Every lookup is answered over TLS, the plain server sees only the
// one bootstrap, and a dead DoT endpoint fails the lookup WITHOUT the closure retrying it through the forced
// re-discovery (which is what its plain path does on a total dial failure): a dotError must be returned as-is.
func TestDoTThroughProductionResolver(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	cert := selfSignedDoT(t, "dot.test")
	dot := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
	dotAddr := dot.serveDoT(t, cert)
	_, port, _ := net.SplitHostPort(dotAddr)
	dotPort = port
	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}, "dot.test": {net.IPv4(127, 0, 0, 1)}})
	plainAddr := plain.servePlain(t)
	_, plainPort, _ = net.SplitHostPort(plainAddr)

	var dumps atomicCounter
	dump := strings.NewReplacer("wlan0", "lo", "dns.mullvad.net", "dot.test",
		"DnsAddresses: [ /192.0.2.53,/198.51.100.53 ]", "DnsAddresses: [ /127.0.0.1 ]").Replace(sampleDumpsysStrictBlocked)
	dumpsysConnectivity = func() string { dumps.add(); return dump }
	setResolverDynamic()

	stop := make(chan struct{})
	var watcher sync.WaitGroup
	watcher.Add(1)
	go func() { // the netlink watcher's shape: refreshNet whenever it likes
		defer watcher.Done()
		for {
			select {
			case <-stop:
				return
			default:
				refreshNet(false)
			}
		}
	}()
	var stopOnce sync.Once
	stopWatcher := func() { stopOnce.Do(func() { close(stop); watcher.Wait() }) }
	t.Cleanup(stopWatcher) // runs BEFORE resetResolverState's restore (LIFO), so a failure cannot leak it
	for i := 0; i < 3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		ips, err := net.DefaultResolver.LookupIPAddr(ctx, "store.example")
		cancel()
		if err != nil || len(ips) != 1 || !ips[0].IP.Equal(storeIP) {
			t.Fatalf("lookup %d through the production resolver = %v, %v", i, ips, err)
		}
	}
	stopWatcher()
	if dot.count("store.example") < 3 {
		t.Fatalf("the DoT server saw %d queries for 3 lookups; every one must go over TLS", dot.count("store.example"))
	}
	if plain.count("store.example") != 0 {
		t.Fatal("the plain server was asked for the name")
	}
	if n := plain.count("dot.test"); n == 0 || n > 2 {
		t.Fatalf("expected exactly one plaintext bootstrap round (an A and an AAAA), the plain server saw %d", n)
	}

	// fail closed THROUGH THE CLOSURE: the endpoint dies; the lookup errors, plain is never asked for the name,
	// and the closure does not force a re-discovery per failed dial -- a dotError is not "all plain servers
	// failed". Go's A and AAAA goroutines may each refresh once on the stale TTL (dnsAddrs checks, then
	// refreshes, without holding netMu across the two), so the honest bound is two for the whole lookup; a
	// closure that took the forced path would add one per failed dial on top (Go makes at least four).
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, dotPort, _ = net.SplitHostPort(closed.Addr().String())
	closed.Close()
	dotMu.Lock()
	dotBoot, dotBootAt = map[string][]string{}, map[string]time.Time{} // the cache file still names 127.0.0.1
	dotMu.Unlock()
	netMu.Lock()
	netAt, dotAddrs = time.Time{}, nil
	netMu.Unlock()
	dumps.reset()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(ctx, "store.example")
	if err == nil {
		t.Fatalf("a dead DoT endpoint answered %v through the production resolver", ips)
	}
	if !strings.Contains(err.Error(), "DoT dot.test unreachable") {
		t.Fatalf("error must name the DoT failure, got: %v", err)
	}
	if plain.count("store.example") != 0 {
		t.Fatal("the plain server was asked for the name; the closure downgraded")
	}
	if n := dumps.get(); n == 0 || n > 2 {
		t.Fatalf("the closure re-discovered %d times for one failed strict lookup; a dotError must not take the forced re-discovery path", n)
	}
}

type atomicCounter struct {
	mu sync.Mutex
	n  int
}

func (c *atomicCounter) add() { c.mu.Lock(); c.n++; c.mu.Unlock() }

func (c *atomicCounter) reset() { c.mu.Lock(); c.n = 0; c.mu.Unlock() }

func (c *atomicCounter) get() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

// The seed carries the DoT posture even when the server list has aged out. The posture is a device-global
// setting and the file is per-boot tmpfs, so it has no network to have left; gating it on the servers' age
// (the first cut did) meant a fork born in the switch window more than dnsKeepMax after the daemon's last
// discovery resolved the store hostname in PLAINTEXT through the public fallback -- the ticket's own log
// signature with dot=off appended.
// ⚠ SUPERSEDED by NWP-20261119-25: "has aged out" no longer drops the servers. A fork seeds the server list at any
// age too: NWP-20261113-19 retired the age rule for the daemon, and a fork that kept applying it started cold after
// any idle spell. The test now pins that the aged servers AND the posture are both seeded.
func TestDoTSeedKeepsPostureWhenServersAged(t *testing.T) {
	resetResolverState(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	saveDNSCache([]string{"192.0.2.53:53"}, "dns.mullvad.net", []string{"194.242.2.2"}, "")
	f := filepath.Join(dir, dnsCacheFile)
	old := time.Now().Add(-2 * dnsKeepMax)
	if err := os.Chtimes(f, old, old); err != nil {
		t.Fatal(err)
	}
	seedDNSFromCache()
	netMu.Lock()
	servers := append([]string(nil), dnsServers...)
	netMu.Unlock()
	if !reflect.DeepEqual(servers, []string{"192.0.2.53:53"}) {
		t.Fatalf("the aged SERVER list was not seeded (%v); a fork seeds a cache of any age (NWP-20261119-25)", servers)
	}
	if host, addrs := currentDoT(); host != "dns.mullvad.net" || !reflect.DeepEqual(addrs, []string{"194.242.2.2:853"}) {
		t.Fatalf("seed dropped the posture with the aged servers: dotHost=%q dotAddrs=%v", host, addrs)
	}
	// the fork's first lookup lands in the switch window: no default block -> the seeded posture is what it has
	dumpsysConnectivity = func() string { return sampleDumpsys }
	tgt := dnsTargetFor(false)
	if tgt.dot != "dns.mullvad.net" || !reflect.DeepEqual(tgt.dotAddrs, []string{"194.242.2.2:853"}) {
		t.Fatalf("first lookup in the switch window would go plain: dot=%q dotAddrs=%v plain=%v", tgt.dot, tgt.dotAddrs, tgt.plain)
	}
}

// The DoT host's own address is bootstrapped through the plain servers ONCE per process -- then from memory --
// and once per boot across processes, through the shared cache file, whose mtime (the server list's age) it
// must not touch.
func TestDoTBootstrapOnce(t *testing.T) {
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", "") // phase 1: NO shared file -- memory is the only thing between lookups
	cert := selfSignedDoT(t, "dot.test")
	dot := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}})
	dotAddr := dot.serveDoT(t, cert)
	_, port, _ := net.SplitHostPort(dotAddr)
	dotPort = port
	plain := newFakeDNS(map[string][]net.IP{"store.example": {storeIP}, "dot.test": {net.IPv4(127, 0, 0, 1)}})
	plainAddr := plain.servePlain(t)

	r := testResolver(func() dnsTarget { return dnsTarget{plain: []string{plainAddr}, dot: "dot.test"} })
	lookup := func() {
		t.Helper()
		ips, err := r.LookupIPAddr(context.Background(), "store.example")
		if err != nil || len(ips) != 1 || !ips[0].IP.Equal(storeIP) {
			t.Fatalf("lookup = %v, %v", ips, err)
		}
	}
	lookup()
	boot := plain.count("dot.test")
	if boot == 0 {
		t.Fatal("no bootstrap query for the DoT host reached the plain server")
	}
	if plain.count("store.example") != 0 {
		t.Fatal("the actual query went to the plain server")
	}
	lookup()
	lookup()
	if n := plain.count("dot.test"); n != boot {
		t.Fatalf("bootstrap repeated: %d plain queries for the DoT host after 3 lookups, %d after 1 (memory cache)", n, boot)
	}

	// phase 2: a fresh process with the daemon's server cache on disk (aged 10s, no DoT line yet)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	saveDNSCache([]string{plainAddr}, "", nil, "")
	cacheFile := filepath.Join(dir, dnsCacheFile)
	aged := time.Now().Add(-10 * time.Second)
	if err := os.Chtimes(cacheFile, aged, aged); err != nil {
		t.Fatal(err)
	}
	dotMu.Lock()
	dotBoot = map[string][]string{}
	dotMu.Unlock()
	lookup()
	boot2 := plain.count("dot.test")
	if boot2 != 2*boot {
		t.Fatalf("a fresh process with no DoT line must bootstrap exactly once more: %d -> %d", boot, boot2)
	}
	// the shared file carries the result, and the server list's age is untouched
	b, err := os.ReadFile(cacheFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "\ndot dot.test 127.0.0.1\n") {
		t.Fatalf("cache file lacks the bootstrapped DoT line:\n%s", b)
	}
	if fi, _ := os.Stat(cacheFile); time.Since(fi.ModTime()) < 8*time.Second {
		t.Fatalf("the bootstrap refreshed the cache file's mtime (age now %v); the server list's age must stay honest", time.Since(fi.ModTime()))
	}

	// phase 3: the next fresh process finds the DoT line -> no plaintext bootstrap at all
	dotMu.Lock()
	dotBoot = map[string][]string{}
	dotMu.Unlock()
	lookup()
	if n := plain.count("dot.test"); n != boot2 {
		t.Fatalf("a process with the shared cache re-bootstrapped in plaintext (%d -> %d)", boot2, n)
	}
	if dot.count("store.example") < 5 {
		t.Fatalf("expected every lookup over TLS, the DoT server saw %d", dot.count("store.example"))
	}
}

// NWP-20261011-36: the egress line must not carry a network's own resolver addresses into login.log (durable,
// shipped in issue reports), and must still tell a discovered list from the public cold-start fallback, which
// is what diagnosed the #64 clobber. Discovered servers -- v4 and v6 -- go out as placeholders, the public ones
// verbatim, and the key is never the legacy dns=[ that log_scrub's dns program redacts.
func TestEgressLineHidesDiscoveredResolvers(t *testing.T) {
	discovered := []string{"192.0.2.53:53", "198.51.100.53:53", "[2001:db8::53]:53", "[fd00:abcd::1]:5353"}
	line := egressLine("wlan0", discovered, "discovered", "")
	if strings.Contains(line, "dns=[") {
		t.Fatalf("the egress line uses the legacy key: %q", line)
	}
	if want := `[resolver] egress iface=wlan0 resolvers=[<net4>:53 <net4>:53 <net6>:53 <net6>:5353] src=discovered dot=off`; line != want {
		t.Fatalf("egress line = %q, want %q", line, want)
	}
	for _, s := range discovered {
		host, _, _ := net.SplitHostPort(s)
		if strings.Contains(line, host) {
			t.Fatalf("a discovered resolver %s survives in %q", host, line)
		}
	}

	fb := fallbackAddrs()
	line = egressLine("wlan0", fb, "PUBLIC-FALLBACK (discovery empty, nothing cached)", "")
	if want := `[resolver] egress iface=wlan0 resolvers=[1.1.1.1:53 8.8.8.8:53 [2606:4700:4700::1111]:53 [2001:4860:4860::8888]:53] src=PUBLIC-FALLBACK (discovery empty, nothing cached) dot=off`; line != want {
		t.Fatalf("the public fallback must print verbatim:\n got %q\nwant %q", line, want)
	}

	// a mixed list keeps the public entry and hides the other; an unparsable entry is <net>, never echoed
	line = egressLine("tun0", []string{"8.8.8.8:53", "10.64.0.1:53", "garbage"}, "discovered", "dns.mullvad.net")
	if want := `[resolver] egress iface=tun0 resolvers=[8.8.8.8:53 <net4>:53 <net>] src=discovered dot=dns.mullvad.net`; line != want {
		t.Fatalf("egress line = %q, want %q", line, want)
	}
	if line := egressLine("", nil, "discovered", ""); line != `[resolver] egress iface="" resolvers=[] src=discovered dot=off` {
		t.Fatalf("empty list: %q", line)
	}
}
