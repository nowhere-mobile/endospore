package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261104-18 (Q152): an issue report names its device's conf keys and never a value.

const plantedConf = "# NOWHERE_X=1\n" +
	"S3_SECRET_KEY=PLANTEDsecretVALUE\n" +
	"GATEWAY_URL=https://planted.example\n" +
	"export Y=2\n" +
	"  Z=3\n" +
	"S3_SECRET_KEY=PLANTEDsecondVALUE\n" +
	"NOWHERE_MULTIDEVICE=1\r\n"

func pointConfAt(t *testing.T, ring, device string) {
	t.Helper()
	oldRing, oldDev := confRingPath, storeConfPath
	confRingPath, storeConfPath = ring, device
	t.Cleanup(func() { confRingPath, storeConfPath = oldRing, oldDev })
}

func TestConfKeyNames_NamesOnlySortedUnique(t *testing.T) {
	p := filepath.Join(t.TempDir(), "nowhere.conf")
	if err := os.WriteFile(p, []byte(plantedConf), 0o600); err != nil {
		t.Fatal(err)
	}
	want := "GATEWAY_URL,NOWHERE_MULTIDEVICE,S3_SECRET_KEY"
	if got := confKeyNames(p); got != want {
		t.Fatalf("confKeyNames = %q, want %q", got, want)
	}
}

func TestConfKeyNames_AbsentUnreadableEmpty(t *testing.T) {
	d := t.TempDir()
	if got := confKeyNames(filepath.Join(d, "missing.conf")); got != "none" {
		t.Fatalf("absent file = %q, want none", got)
	}
	if got := confKeyNames(d); got != "unreadable" {
		t.Fatalf("directory = %q, want unreadable", got)
	}
	e := filepath.Join(d, "empty.conf")
	if err := os.WriteFile(e, []byte("# only a comment=1\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := confKeyNames(e); got != "none" {
		t.Fatalf("keyless file = %q, want none", got)
	}
}

func TestReportConfKeys_StatusAtBothScopesNoValue(t *testing.T) {
	d := t.TempDir()
	dev := filepath.Join(d, "device.conf")
	ring := filepath.Join(d, "ring.conf")
	if err := os.WriteFile(dev, []byte(plantedConf), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ring, []byte("NOWHERE_GATEWAY_DEFAULT=https://planted.example/ring\nOTA_RING=PLANTEDring\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pointConfAt(t, ring, dev)
	t.Setenv("NOWHERE_DIR", d)
	for _, deviceScope := range []bool{true, false} {
		r := buildIssueReport("bobprofile", deviceScope, "", nil, nil)
		if got := r.Status["conf_device_keys"]; got != "GATEWAY_URL,NOWHERE_MULTIDEVICE,S3_SECRET_KEY" {
			t.Errorf("scope=%v conf_device_keys = %q", deviceScope, got)
		}
		if got := r.Status["conf_ring_keys"]; got != "NOWHERE_GATEWAY_DEFAULT,OTA_RING" {
			t.Errorf("scope=%v conf_ring_keys = %q", deviceScope, got)
		}
		b, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"PLANTED", "planted.example"} {
			if strings.Contains(string(b), bad) {
				t.Errorf("scope=%v: a planted conf value %q reached the report", deviceScope, bad)
			}
		}
	}
}

func TestReportConfKeys_RingAndDeviceIndependent(t *testing.T) {
	d := t.TempDir()
	ring := filepath.Join(d, "ring.conf")
	if err := os.WriteFile(ring, []byte("OTA_RING=x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pointConfAt(t, ring, filepath.Join(d, "absent.conf"))
	t.Setenv("NOWHERE_DIR", d)
	r := buildIssueReport("", true, "", nil, nil)
	if r.Status["conf_ring_keys"] != "OTA_RING" || r.Status["conf_device_keys"] != "none" {
		t.Fatalf("ring/device = %q / %q", r.Status["conf_ring_keys"], r.Status["conf_device_keys"])
	}
}
