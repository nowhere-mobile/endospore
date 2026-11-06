package main

// NWP-20261114-24: this phone's device label, the name that sits beside its chip slot in a profile's vault.
//
// Backlog row "The unit label embeds the unit id, so the device-naming rule decided in `NWP-20260912-01` cannot ship";
// decided 2026-10-22 (docs/product-decisions.md, #37, Q080): the label sits beside each phone's chip slot, inside the
// vault, set at first-run setup and seeded from Build.MODEL. The vault head is vaultMagic + PLAINTEXT JSON at a ref
// the store reads, so the label is SEALED under the profile's DK (keyslot.LabelSealed): a clear label would tell the
// store which phone a profile uses. Only the DK is common to every slot, so every phone that opens the profile can
// read every other phone's label, which is what the 2026-09-12 naming rule needs.

import (
	"encoding/base64"
	"errors"
	"os"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// deviceLabelPath holds the name the owner gave this phone (SET-DEVICE-LABEL, sent by the gate's first-run setup).
// Device-local, user 0, 0600, and DURABLE: it survives power-off BY DESIGN, because it names the handset, not a
// profile. It leaves the phone only sealed under a profile's DK, beside this phone's chip slot. A var (not const) so
// a test can point it at a temp file.
var deviceLabelPath = "/data/nowhere/device-label"

// deviceModelFn is the label's seed when the owner has set none: ro.product.model (Build.MODEL). A var so a test can
// stub it.
var deviceModelFn = func() string { return getprop("ro.product.model") }

const maxDeviceLabelRunes = 40

var (
	deviceLabelMu     sync.Mutex
	errBadDeviceLabel = errors.New("invalid device label")
)

// validDeviceLabel reports whether s, trimmed, is 1-40 printable runes of valid UTF-8 (no newline, tab or other
// control rune).
func validDeviceLabel(s string) bool {
	t := strings.TrimSpace(s)
	if !utf8.ValidString(t) {
		return false
	}
	if n := utf8.RuneCountInString(t); n < 1 || n > maxDeviceLabelRunes {
		return false
	}
	for _, r := range t {
		if !unicode.IsPrint(r) {
			return false
		}
	}
	return true
}

// deviceLabel is the label this phone's next chip slot carries: the owner's name when the file holds a valid one,
// else the model when it is valid, else "".
func deviceLabel() string {
	if b, err := os.ReadFile(deviceLabelPath); err == nil {
		if t := strings.TrimSpace(string(b)); validDeviceLabel(t) {
			return t
		}
	}
	if m := strings.TrimSpace(deviceModelFn()); validDeviceLabel(m) {
		return m
	}
	return ""
}

// setDeviceLabel stores s (trimmed) as this phone's label, 0600, by temp file + rename. An invalid label is refused
// with errBadDeviceLabel and nothing is written.
func setDeviceLabel(s string) error {
	if !validDeviceLabel(s) {
		return errBadDeviceLabel
	}
	deviceLabelMu.Lock()
	defer deviceLabelMu.Unlock()
	tmp := deviceLabelPath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(strings.TrimSpace(s) + "\n")
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, deviceLabelPath)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// sealSlotLabel is keyslot.LabelSealed for label: base64(seal(dk, label)), the shape vault.Pin has; "" for "".
func sealSlotLabel(dk []byte, label string) string {
	if label == "" {
		return ""
	}
	return base64.StdEncoding.EncodeToString(seal(dk, []byte(label)))
}

// openSlotLabel is sealSlotLabel's inverse. It returns "" for "", for a wrong DK, for bytes that do not open and for
// an opened value that is not a valid label. It never panics (unwrap, not unseal).
func openSlotLabel(dk []byte, s string) string {
	if s == "" {
		return ""
	}
	pt, ok := unwrap(dk, s)
	if !ok || !validDeviceLabel(string(pt)) {
		return ""
	}
	return string(pt)
}
