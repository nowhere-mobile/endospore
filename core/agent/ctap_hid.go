package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

// CTAPHID transport over /dev/hidraw (#81 P4b). A FIDO2 key plugged into the FP3's USB-C (OTG) enumerates as
// a HID device; the kernel exposes it at /dev/hidrawN. CTAPHID frames CTAP2 CBOR commands into 64-byte HID
// reports. This runs in the ROOT worker's domain (the confined nowhere_agent domain can't open /dev/hidraw);
// for the P4b bring-up it's exercised as the `fido2-info` CLI subcommand via an adb-root shell -- no image
// flash needed to prove the key talks.

const (
	hidReportSize  = 64
	hidBroadcast   = 0xffffffff
	ctaphidInit    = 0x86 // allocate a channel
	ctaphidCBOR    = 0x90 // carry a CTAP2 CBOR command
	ctaphidError   = 0xbf
	ctaphidKeepAlv = 0xbb        // authenticator is busy (user presence / PIN) -> keep reading
	ctaphidMaxMsg  = 57 + 128*59 // 7609: the largest CTAPHID message (init packet + continuations SEQ 0..0x7f)
)

// ctaphidReportWait is how long one read waits for the next report. It restarts with EVERY report, KEEPALIVEs and
// other channels' reports included, so on its own it never bounds a key that keeps signalling busy.
var ctaphidReportWait = 30 * time.Second

// ctaphidRecvBudget bounds the whole of one recv: the init packet, every KEEPALIVE, every other channel's report and
// every continuation. It is what ends a key that keeps signalling busy (NWP-20261113-09). Both are vars so tests
// shrink them.
var ctaphidRecvBudget = 60 * time.Second

// hidLinkError marks a TRANSPORT failure on the hidraw link: a poll or read error, a read that timed out, recv's budget
// spent, or a failed or short write. A framing refusal (an oversized BCNT, a SEQ gap, a mid-message init packet, send's
// payload limit) is NOT one: a fresh session per slot starts clean. assertAnySlot stops at it (NWP-20261113-09).
type hidLinkError struct{ err error }

func (e *hidLinkError) Error() string { return e.err.Error() }
func (e *hidLinkError) Unwrap() error { return e.err }

// errNoFidoHidraw is findFidoHidraw's answer when no FIDO hidraw appeared within its wait; assertAnySlot stops at it.
var errNoFidoHidraw = errors.New("no FIDO hidraw device found (key plugged into USB-C? USB-OTG on?)")

// findFidoHidraw scans /dev/hidraw* for the FIDO usage page (0xF1D0 -> report-descriptor bytes 06 D0 F1).
//
// NWP-20260823-08 (ii): the scan WAITS, because its callers race cold enumeration. Every USB assert runs
// usb_host on -> a ~2s settle -> this scan -> usb_host off on failure, and a USB key needs ~2-3s from the
// host-flip to hidraw appearing -- so a single-shot scan lost the race on EVERY attempt, and the off-flip
// between attempts restarted enumeration from zero each round (device-proven on lynx 2026-08-23: three
// resume asserts, 14-19s apart, all "no FIDO hidraw device found", zero avc denials, key enumerated fine
// once left alone). Bounded poll: 16 x 500ms = ~8s past the flip covers the observed 2-3s with margin, and
// a key that is genuinely absent still fails inside the caller's existing timeout budget. NFC is untouched
// (this function is the USB path only).
func findFidoHidraw() (string, error) {
	for try := 0; try < 16; try++ {
		matches, _ := filepath.Glob("/dev/hidraw*")
		for _, dev := range matches {
			base := filepath.Base(dev)
			desc, err := os.ReadFile("/sys/class/hidraw/" + base + "/device/report_descriptor")
			if err != nil {
				continue
			}
			if bytes.Contains(desc, []byte{0x06, 0xd0, 0xf1}) {
				return dev, nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return "", errNoFidoHidraw
}

// ctapHID is one CTAPHID session on an open hidraw fd, with an allocated channel id.
type ctapHID struct {
	fd  int
	cid uint32
}

func openCTAPHID(path string) (*ctapHID, error) {
	fd, err := unix.Open(path, unix.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	h := &ctapHID{fd: fd, cid: hidBroadcast}
	if err := h.initChannel(); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return h, nil
}

func (h *ctapHID) Close() { unix.Close(h.fd) }

// initChannel does CTAPHID_INIT on the broadcast channel: send an 8-byte nonce, get it echoed back plus a
// freshly allocated 4-byte channel id (bytes 8..12 of the response).
func (h *ctapHID) initChannel() error {
	nonce := make([]byte, 8)
	rand.Read(nonce)
	if err := h.send(ctaphidInit, nonce); err != nil {
		return err
	}
	_, resp, err := h.recv()
	if err != nil {
		return err
	}
	if len(resp) < 17 || !bytes.Equal(resp[:8], nonce) {
		return errors.New("CTAPHID_INIT: bad nonce echo")
	}
	h.cid = binary.BigEndian.Uint32(resp[8:12])
	return nil
}

// cbor sends a CTAP2 command (cmd byte + CBOR params) and returns the CTAP2 status byte + CBOR response body.
func (h *ctapHID) cbor(ctapCmd byte, params []byte) (status byte, body []byte, err error) {
	payload := append([]byte{ctapCmd}, params...)
	if err = h.send(ctaphidCBOR, payload); err != nil {
		return 0, nil, err
	}
	cmd, resp, err := h.recv()
	if err != nil {
		return 0, nil, err
	}
	if cmd == ctaphidError {
		if len(resp) > 0 {
			return 0, nil, fmt.Errorf("CTAPHID error 0x%02x", resp[0])
		}
		return 0, nil, errors.New("CTAPHID error")
	}
	if len(resp) < 1 {
		return 0, nil, errors.New("empty CTAP2 response")
	}
	return resp[0], resp[1:], nil // resp[0] = CTAP2 status (0x00 = OK)
}

// send frames data into an initialization packet + continuation packets (64 bytes each).
func (h *ctapHID) send(cmd byte, data []byte) error {
	if len(data) > ctaphidMaxMsg {
		return fmt.Errorf("CTAPHID payload of %d bytes exceeds the %d-byte limit", len(data), ctaphidMaxMsg)
	}
	pkt := make([]byte, hidReportSize)
	binary.BigEndian.PutUint32(pkt[0:4], h.cid)
	pkt[4] = cmd
	binary.BigEndian.PutUint16(pkt[5:7], uint16(len(data)))
	n := copy(pkt[7:], data) // up to 57 bytes in the init packet
	if err := h.writeReport(pkt); err != nil {
		return err
	}
	seq := byte(0)
	for n < len(data) {
		for i := range pkt {
			pkt[i] = 0
		}
		binary.BigEndian.PutUint32(pkt[0:4], h.cid)
		pkt[4] = seq & 0x7f // continuation: high bit clear
		n += copy(pkt[5:], data[n:])
		if err := h.writeReport(pkt); err != nil {
			return err
		}
		seq++
	}
	return nil
}

// recv reassembles a response, transparently swallowing KEEPALIVE frames (the key sends these while it waits
// for a touch / PIN). Returns the response command byte + the assembled body. Continuations must arrive in SEQ order,
// and an oversized or interleaved message is refused. The whole recv, KEEPALIVEs, other channels' reports and
// continuations included, ends within ctaphidRecvBudget: every read is given its end (NWP-20261113-09).
func (h *ctapHID) recv() (cmd byte, body []byte, err error) {
	end := time.Now().Add(ctaphidRecvBudget)
	for {
		pkt, err := h.readReport(end)
		if err != nil {
			return 0, nil, err
		}
		if binary.BigEndian.Uint32(pkt[0:4]) != h.cid {
			continue // a stray report on another channel
		}
		cmd = pkt[4]
		if cmd == ctaphidKeepAlv {
			continue // still working -> wait for the real answer
		}
		total := int(binary.BigEndian.Uint16(pkt[5:7]))
		if total > ctaphidMaxMsg {
			return 0, nil, fmt.Errorf("CTAPHID message of %d bytes exceeds the %d-byte limit", total, ctaphidMaxMsg)
		}
		buf := append([]byte(nil), pkt[7:]...)
		seq := 0
		for len(buf) < total {
			cont, err := h.readReport(end)
			if err != nil {
				return 0, nil, err
			}
			if binary.BigEndian.Uint32(cont[0:4]) != h.cid {
				continue // a report on another channel
			}
			if cont[4]&0x80 != 0 {
				return 0, nil, errors.New("CTAPHID: a new message began before the last one ended")
			}
			if int(cont[4]) != seq {
				return 0, nil, fmt.Errorf("CTAPHID continuation out of order: expected SEQ %d, received %d", seq, cont[4])
			}
			buf = append(buf, cont[5:]...)
			seq++
		}
		return cmd, buf[:total], nil
	}
}

func (h *ctapHID) writeReport(pkt []byte) error {
	// hidraw reads the first byte of a write as the report number, and usbhid drops it when it is 0x00. FIDO HID keys
	// use no numbered reports, so the 64-byte packet goes out behind a 0x00, as libfido2 and python-fido2 do on Linux.
	buf := make([]byte, hidReportSize+1)
	copy(buf[1:], pkt)
	n, err := unix.Write(h.fd, buf)
	if err != nil {
		return &hidLinkError{err}
	}
	if n != len(buf) {
		return &hidLinkError{fmt.Errorf("short hidraw write: %d of %d bytes", n, len(buf))}
	}
	return nil
}

// readReport polls for a 64-byte report with a generous deadline (a user-presence prompt can take a while;
// KEEPALIVEs keep the poll fed), ctaphidReportWait from now but never past end, the end of recv's budget. The
// per-report wait restarts with every report, so it is recv's budget, not this wait, that keeps a key which keeps
// signalling busy from hanging the worker forever (NWP-20261113-09). Every failure here is a *hidLinkError.
func (h *ctapHID) readReport(end time.Time) ([]byte, error) {
	deadline, why := time.Now().Add(ctaphidReportWait), "CTAPHID read timeout (no touch / key removed?)"
	if deadline.After(end) {
		deadline, why = end, fmt.Sprintf("CTAPHID: no answer within %v (the key kept signalling busy, or sent only other channels' reports)", ctaphidRecvBudget)
	}
	for {
		ms := int(time.Until(deadline).Milliseconds())
		if ms <= 0 {
			return nil, &hidLinkError{errors.New(why)}
		}
		fds := []unix.PollFd{{Fd: int32(h.fd), Events: unix.POLLIN}}
		n, err := unix.Poll(fds, ms)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return nil, &hidLinkError{err}
		}
		if n == 0 {
			continue // the wait ran out: the timeout return above
		}
		buf := make([]byte, hidReportSize)
		r, err := unix.Read(h.fd, buf)
		if err != nil {
			return nil, &hidLinkError{err}
		}
		if r == 0 {
			continue
		}
		return buf, nil
	}
}
