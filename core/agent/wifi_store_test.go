package main

import (
	"strings"
	"testing"
)

// #98 v2: the daemon-side store parser extracts quoted-PSK + open networks, skips hex SSIDs/PSKs and EAP.
func TestParseWifiStore(t *testing.T) {
	fixture := `<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<WifiConfigStoreData>
<int name="Version" value="3" />
<NetworkList>
<Network>
<WifiConfiguration>
<string name="ConfigKey">&quot;HomeNet&quot;WPA_PSK</string>
<string name="SSID">&quot;HomeNet&quot;</string>
<string name="PreSharedKey">&quot;pass with spaces &amp; symbols&quot;</string>
<int name="MacRandomizationSetting" value="1" />
<null name="WEPKeys" />
</WifiConfiguration>
</Network>
<Network>
<WifiConfiguration>
<string name="ConfigKey">&quot;WorkMac&quot;WPA_PSK</string>
<string name="SSID">&quot;WorkMac&quot;</string>
<string name="PreSharedKey">&quot;workpw&quot;</string>
<int name="MacRandomizationSetting" value="0" />
</WifiConfiguration>
</Network>
<Network>
<WifiConfiguration>
<string name="ConfigKey">&quot;Cafe Open&quot;NONE</string>
<string name="SSID">&quot;Cafe Open&quot;</string>
<null name="PreSharedKey" />
</WifiConfiguration>
</Network>
<Network>
<WifiConfiguration>
<string name="ConfigKey">&quot;Office&quot;EAP</string>
<string name="SSID">&quot;Office&quot;</string>
<null name="PreSharedKey" />
</WifiConfiguration>
</Network>
<Network>
<WifiConfiguration>
<string name="ConfigKey">&quot;HexNet&quot;WPA_PSK</string>
<string name="SSID">&quot;HexNet&quot;</string>
<string name="PreSharedKey">0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef</string>
</WifiConfiguration>
</Network>
<Network>
<WifiConfiguration>
<string name="ConfigKey">4e6f6e55746638WPA_PSK</string>
<string name="SSID">4e6f6e55746638</string>
<string name="PreSharedKey">&quot;pw&quot;</string>
</WifiConfiguration>
</Network>
</NetworkList>
</WifiConfigStoreData>`

	got := parseWifiStore([]byte(fixture))
	want := []wifiEnt{
		{"HomeNet", "pass with spaces & symbols", 1}, // quoted PSK; mac=PERSISTENT (randomized)
		{"WorkMac", "workpw", 0},                     // #118: mac=NONE (real MAC) carried for the allowlist AP
		{"Cafe Open", "", -1},                        // open network, store recorded no mac -> -1 (gate default)
		// Office (EAP), HexNet (raw hex PSK), 4e6f... (hex ssid) all skipped
	}
	if len(got) != len(want) {
		t.Fatalf("parseWifiStore: got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("entry %d: got %+v want %+v", i, got[i], want[i])
		}
	}
}

// NWP-20261031-09: the daemon-side capture keeps or skips exactly what the chooser's WifiMirrorLine.encode does.
func TestParseWifiStoreQuotesAndTabs(t *testing.T) {
	net := func(ssid, psk string) []byte {
		p := `<null name="PreSharedKey" />`
		if psk != "" {
			p = `<string name="PreSharedKey">` + psk + `</string>`
		}
		return []byte("<Network>\n<WifiConfiguration>\n<string name=\"SSID\">" + ssid + "</string>\n" + p + "\n</WifiConfiguration>\n</Network>\n")
	}
	q := "&quot;"
	cases := []struct {
		name      string
		ssid, psk string
		want      []wifiEnt // nil = skipped
	}{
		{"inner quote in ssid", q + "a" + q + "b" + q, q + "pw" + q, []wifiEnt{{`a"b`, "pw", -1}}},
		{"ssid quoted twice", q + q + "Net" + q + q, q + "pw" + q, []wifiEnt{{`"Net"`, "pw", -1}}},
		{"psk ends in a quote", q + "Net" + q, q + "pw" + q + q, []wifiEnt{{"Net", `pw"`, -1}}},
		{"psk holds a tab", q + "Net" + q, q + "a&#9;b" + q, nil},
		{"psk holds a newline", q + "Net" + q, q + "a&#10;b" + q, nil},
		{"blank ssid", q + " " + q, q + "pw" + q, nil},
		{"ssid of control bytes only", q + "&#9;" + q, q + "pw" + q, nil},
		{"ssid holds a tab", q + "&#9;x" + q, q + "pw" + q, nil},
		{"unenclosed ssid", "Net", q + "pw" + q, nil},
		{"lone quote ssid", q, q + "pw" + q, nil},
		{"lone quote psk", q + "Net" + q, q, nil},
		{"300-byte psk", q + "Net" + q, q + strings.Repeat("p", 300) + q, nil},
		{"edge spaces kept", q + " Net " + q, q + " pw " + q, []wifiEnt{{" Net ", " pw ", -1}}},
	}
	for _, c := range cases {
		got := parseWifiStore(net(c.ssid, c.psk))
		if len(got) != len(c.want) || (len(got) == 1 && got[0] != c.want[0]) {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}
