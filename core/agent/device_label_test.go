package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// NWP-20261114-24: this phone's device label (device_label.go), sealed under the DK beside its own chip slot.

// useTempDeviceLabel points deviceLabelPath into t.TempDir() and stubs the model seam to "" (the test sets it), and
// restores both when the test ends. It returns the path.
func useTempDeviceLabel(t *testing.T) string {
	t.Helper()
	oldPath, oldModel := deviceLabelPath, deviceModelFn
	deviceLabelPath = filepath.Join(t.TempDir(), "device-label")
	deviceModelFn = func() string { return "" }
	t.Cleanup(func() { deviceLabelPath, deviceModelFn = oldPath, oldModel })
	return deviceLabelPath
}

func writeDeviceLabelFile(t *testing.T, body string) {
	t.Helper()
	if err := os.WriteFile(deviceLabelPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestValidDeviceLabel(t *testing.T) {
	for _, c := range []struct {
		in   string
		want bool
	}{
		{"Pixel 7a", true},
		{"  FP3  ", true},
		{"Ivy's Pixel", true},
		{strings.Repeat("a", 40), true},
		{strings.Repeat("é", 40), true},
		{"", false},
		{"   ", false},
		{strings.Repeat("a", 41), false},
		{strings.Repeat("é", 41), false},
		{"a\nb", false},
		{"a\rb", false},
		{"a\tb", false},
		{"a\x00b", false},
		{"a\x1bb", false},
		{"a b", false},
		{"\xff", false},
		{"ok\xffok", false},
	} {
		if got := validDeviceLabel(c.in); got != c.want {
			t.Errorf("validDeviceLabel(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestDeviceLabelPrefersTheFile(t *testing.T) {
	useTempDeviceLabel(t)
	deviceModelFn = func() string { return "Pixel 7a" }
	writeDeviceLabelFile(t, "Kitchen phone\n")
	if got := deviceLabel(); got != "Kitchen phone" {
		t.Errorf("deviceLabel() = %q, want the file's \"Kitchen phone\"", got)
	}
}

func TestDeviceLabelFallsBackToTheModel(t *testing.T) {
	useTempDeviceLabel(t)
	deviceModelFn = func() string { return " Pixel 7a\n" }
	if got := deviceLabel(); got != "Pixel 7a" {
		t.Errorf("no file: deviceLabel() = %q, want the model \"Pixel 7a\"", got)
	}
	for _, bad := range []string{"a\nb", strings.Repeat("x", 41), "\n", "\xff"} {
		writeDeviceLabelFile(t, bad)
		if got := deviceLabel(); got != "Pixel 7a" {
			t.Errorf("file %q: deviceLabel() = %q, want the model \"Pixel 7a\"", bad, got)
		}
	}
	if err := os.Remove(deviceLabelPath); err != nil {
		t.Fatal(err)
	}
	deviceModelFn = func() string { return "" }
	if got := deviceLabel(); got != "" {
		t.Errorf("no file, no model: deviceLabel() = %q, want \"\"", got)
	}
	deviceModelFn = func() string { return "Pix\x07el" }
	if got := deviceLabel(); got != "" {
		t.Errorf("no file, a model with a control rune: deviceLabel() = %q, want \"\"", got)
	}
}

func TestSetDeviceLabelRoundTrip(t *testing.T) {
	p := useTempDeviceLabel(t)
	deviceModelFn = func() string { return "Pixel 7a" }
	if err := setDeviceLabel("  Work phone "); err != nil {
		t.Fatalf("setDeviceLabel: %v", err)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Errorf("device-label mode is %o, want 600", st.Mode().Perm())
	}
	if b, _ := os.ReadFile(p); string(b) != "Work phone\n" {
		t.Errorf("device-label holds %q, want \"Work phone\\n\"", b)
	}
	if got := deviceLabel(); got != "Work phone" {
		t.Errorf("deviceLabel() = %q, want \"Work phone\"", got)
	}
	if _, err := os.Stat(p + ".tmp"); err == nil {
		t.Error("the temp file was left behind")
	}
}

func TestSetDeviceLabelRefusesAnInvalidLabel(t *testing.T) {
	p := useTempDeviceLabel(t)
	writeDeviceLabelFile(t, "Old name\n")
	for _, bad := range []string{"", "   ", "a\nb", "a\x00b", strings.Repeat("y", 41)} {
		if err := setDeviceLabel(bad); !errors.Is(err, errBadDeviceLabel) {
			t.Errorf("setDeviceLabel(%q) = %v, want errBadDeviceLabel", bad, err)
		}
		if b, _ := os.ReadFile(p); string(b) != "Old name\n" {
			t.Errorf("after setDeviceLabel(%q) the file holds %q, want it unchanged", bad, b)
		}
	}
	if _, err := os.Stat(p + ".tmp"); err == nil {
		t.Error("a refused label left a temp file")
	}
}

func TestSlotLabelRoundTrip(t *testing.T) {
	dk := randBytes(32)
	const label = "Pixel 7a"
	s := sealSlotLabel(dk, label)
	if s == "" {
		t.Fatal("sealSlotLabel returned \"\" for a label")
	}
	if got := openSlotLabel(dk, s); got != label {
		t.Errorf("openSlotLabel(sealSlotLabel(%q)) = %q", label, got)
	}
	if strings.Contains(s, label) {
		t.Errorf("the sealed label %q holds the label in the clear", s)
	}
	if raw, err := base64.StdEncoding.DecodeString(s); err != nil || bytes.Contains(raw, []byte(label)) {
		t.Errorf("the sealed label decodes (%v) to bytes that hold the label in the clear", err)
	}
	if got := sealSlotLabel(dk, ""); got != "" {
		t.Errorf("sealSlotLabel(\"\") = %q, want \"\"", got)
	}
	if got := openSlotLabel(dk, ""); got != "" {
		t.Errorf("openSlotLabel(\"\") = %q, want \"\"", got)
	}
	if got := openSlotLabel(randBytes(32), s); got != "" {
		t.Errorf("a wrong DK opened the label to %q, want \"\"", got)
	}
	if got := openSlotLabel(dk, "!!"); got != "" {
		t.Errorf("garbage opened to %q, want \"\"", got)
	}
	if got := openSlotLabel(dk, base64.StdEncoding.EncodeToString([]byte(label))); got != "" {
		t.Errorf("an unsealed base64 label opened to %q, want \"\"", got)
	}
}

// TestTieSlotsSealsThisPhonesLabel: the tie's new `se` slot carries THIS phone's label sealed under the DK, no other slot
// changes, and the encoded vault does not hold the label in the clear.
func TestTieSlotsSealsThisPhonesLabel(t *testing.T) {
	useTempDeviceLabel(t)
	const label = "Ivy's Pixel"
	writeDeviceLabelFile(t, label+"\n")
	const n, p = "labeltie", "labeltie pass"
	dk := randBytes(32)
	seOther := []byte("label-other-phone")
	other := keyslot{Kind: "se", Wrapped: wrap(kekSE(n, p, seOther), dk)}
	recov := keyslot{Kind: "recovery", Wrapped: wrap(randBytes(32), dk)}
	fido := keyslot{Kind: "fido2", Wrapped: wrap(randBytes(32), dk), CredID: "Y3JlZA==", Salt: "c2FsdA==", Label: "USB key"}
	v := &vault{V: 2, Slots: []keyslot{
		{Kind: "pass", Wrapped: wrap(randBytes(32), dk)},
		recov, other, fido,
	}}
	tieSlots(v, n, p, seA, dk)

	var mine []keyslot
	labelled := 0
	for _, s := range v.Slots {
		if s.LabelSealed != "" {
			labelled++
		}
		if s.Kind == "se" {
			if _, ok := unwrap(kekSE(n, p, seA), s.Wrapped); ok {
				mine = append(mine, s)
			}
		}
	}
	if len(mine) != 1 {
		t.Fatalf("this phone opens %d se slots after the tie, want 1", len(mine))
	}
	if got := openSlotLabel(dk, mine[0].LabelSealed); got != deviceLabel() || got != label {
		t.Errorf("this phone's slot label opens to %q, want %q", got, label)
	}
	if labelled != 1 {
		t.Errorf("%d slots carry a label, want only this phone's", labelled)
	}
	want := []keyslot{recov, other, fido}
	var rest []keyslot
	for _, s := range v.Slots {
		if !reflect.DeepEqual(s, mine[0]) {
			rest = append(rest, s)
		}
	}
	if !reflect.DeepEqual(rest, want) {
		t.Errorf("the other slots changed in the tie:\n got %+v\nwant %+v", rest, want)
	}
	enc := serializeVault(v)
	if bytes.Contains(enc, []byte(label)) || bytes.Contains(enc, []byte("Ivy")) {
		t.Errorf("the encoded vault holds the label in the clear: %s", enc)
	}
	if !bytes.Contains(enc, []byte(`"label_sealed"`)) {
		t.Errorf("the encoded vault has no label_sealed field: %s", enc)
	}
}

// TestSetDeviceLabelVerb: SET-DEVICE-LABEL from the user-0 gate writes the file (OK), refuses an invalid label
// (ERR-ARGS), answers ERR when the write fails, and answers a roamed peer DENIED with nothing written.
func TestSetDeviceLabelVerb(t *testing.T) {
	f, _, _ := gateOnlyFixture(t, "SET-DEVICE-LABEL", nil)
	p := deviceLabelPath
	drive := func(rest string) string {
		t.Helper()
		defer waitGateOnly(t)
		reply, _, answered := gateOnlyDrive(t, f.dest, "SET-DEVICE-LABEL", rest, 5*time.Second)
		if !answered {
			t.Fatalf("SET-DEVICE-LABEL %q: no reply within 5 s", rest)
		}
		return reply
	}

	gatePeer(t, gateRoamedA)
	if got := drive("Roamed name\n"); got != "DENIED" {
		t.Errorf("a roamed peer got %q, want DENIED", got)
	}
	if _, err := os.Stat(p); err == nil {
		t.Error("a roamed peer's label was written")
	}

	gatePeer(t, 10123)
	if got := drive("Hall phone\n"); got != "OK" {
		t.Errorf("a valid label got %q, want OK", got)
	}
	if b, _ := os.ReadFile(p); string(b) != "Hall phone\n" {
		t.Errorf("device-label holds %q, want \"Hall phone\\n\"", b)
	}
	for _, bad := range []string{"a\x01b\n", "\n", strings.Repeat("z", 41) + "\n"} {
		if got := drive(bad); got != "ERR-ARGS" {
			t.Errorf("label %q got %q, want ERR-ARGS", bad, got)
		}
		if b, _ := os.ReadFile(p); string(b) != "Hall phone\n" {
			t.Errorf("after label %q the file holds %q, want it unchanged", bad, b)
		}
	}
	deviceLabelPath = filepath.Join(t.TempDir(), "missing", "device-label")
	if got := drive("Hall phone\n"); got != "ERR" {
		t.Errorf("a failed write got %q, want ERR", got)
	}
}
