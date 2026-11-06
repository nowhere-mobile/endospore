package main

// NWP-20261123-22: the WRITE side of the next-sign-in skip notice.
//
// Backlog row "`pushProfile`'s tombstone skips report "Saved" and the next login tells nobody (#119)"; decided
// 2026-11-01 (h50 #6), 2026-11-02 (h53 #2) and, for the words, 2026-10-30 (h48 #5) in docs/product-decisions.md.
//
// pushProfile skips a seal when the bare head is a tombstone: the profile was deleted, or its passphrase was changed
// on another phone. The skip is right (sealing old-passphrase refs forks the account), but the sign-out reports
// "Saved" and this phone's unsaved changes go nowhere. The decision: tell the NEXT sign-in. The notice sits at one
// fixed address worked out from the profile's DK, which both passphrases open, and it is sealed under that DK. This
// phone opens the DK from the vault its own sign-in restored (the bare restore receipt names it; a rotation leaves
// that blob in the store, TestSkipNoticeOldVaultSurvivesRotation).
//
// It writes only when the restored vault's recovery entry point still resolves (a rotation re-points it) or the
// vault names none. A tombstone there is a delete, and a delete must not leave a new object under the profile. A read
// that fails writes nothing; the next skip asks again. The record names the phone (its label, never a unit id) and a
// minute, with no app list (h48 #5). The reader is NWP-20261125-19, below.
//
// NWP-20261125-19: the READ side's agent half. GET-SKIP-NOTICE opens the DK under the session's CURRENT credential (a
// rotation keeps the DK, so the new passphrase works out the same address) and answers the notice when its time is
// later than the profile's shown record. SKIP-NOTICE-SHOWN records the time shown. The chooser's words (h48 #5) and
// its call to SKIP-NOTICE-SHOWN are the next slice.

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const skipNoticeInfo = "nowhere-skip-notice-v1"

// skipNoticeNow is the notice's clock. A var so a test can pin it.
var skipNoticeNow = time.Now

// skipNoticeRecord is the sealed body: exactly the phone's label and a unix time at minute precision. No app list,
// no profile name, no unit id and nothing derived from one.
type skipNoticeRecord struct {
	Phone string `json:"phone"` // deviceLabel(): the stored slot label (NWP-20261114-24), else Build.MODEL; may be ""
	Time  int64  `json:"time"`  // unix seconds, truncated to the minute
}

// skipNoticeRef is the notice's fixed address: hex(HMAC-SHA256(dk, "nowhere-skip-notice-v1")), the leaseable
// 64-hex ref shape. Keyed by the DK, so it links to neither the name nor either passphrase.
func skipNoticeRef(dk []byte) string {
	m := hmac.New(sha256.New, dk)
	m.Write([]byte(skipNoticeInfo))
	return hex.EncodeToString(m.Sum(nil))
}

// skipNoticeDK opens the profile's DK from the vault named by THIS session's BARE restore receipt. A scope name
// ("alice#de") uses its bare name's receipt: a scope's receipt names a scope manifest head, not the vault. Any
// failure is ok=false; it never panics.
func skipNoticeDK(base, profile, pass string) (dk []byte, v *vault, ok bool) {
	bare := profile
	if i := strings.IndexByte(profile, '#'); i >= 0 {
		bare = profile[:i]
	}
	head := restoreReceiptHead(profileRefV2(bare, pass))
	if head == "" {
		return nil, nil, false
	}
	var blob []byte
	if recovered(func() { blob = headBlobGet(base, head) }) != nil {
		return nil, nil, false
	}
	v, isV := parseVault(blob)
	if !isV {
		return nil, nil, false
	}
	if dk = openVaultDK(v, bare, pass); dk == nil {
		return nil, nil, false
	}
	return dk, v, true
}

// skipNoticeRecoveryLive is the h53 #2 check on the restored vault's recovery entry point: write when the vault names
// none, or when it still resolves (a rotation re-points it). A tombstone there is a delete: write nothing. A failed
// read, or a ref the store does not hold, writes nothing (the next skip asks again). getRefBytesStrict, never getRef
// or refExists: those read a cap 403 or a transport error as absence.
func skipNoticeRecoveryLive(base string, v *vault) (write bool, why string) {
	if v.RecoveryRef == "" {
		return true, ""
	}
	var b []byte
	var present bool
	if recovered(func() { b, present = getRefBytesStrict(base, v.RecoveryRef) }) != nil {
		return false, "could not read"
	}
	if !present {
		return false, "could not read"
	}
	if strings.TrimSpace(string(b)) == "" {
		return false, "deleted"
	}
	return true, ""
}

// skipNoticeOpenBracket is the cap bracket pushProfile holds open, or 0.
func skipNoticeOpenBracket() uint64 {
	capWriteMu.Lock()
	defer capWriteMu.Unlock()
	return capBracketOpen
}

// writeSkipNotice is the one call each pushProfile tombstone exit makes, before its return. It logs exactly one line,
// with no name and no ref. The skip stays a skip: nothing it does can panic out of pushProfile or turn the skip into
// a refusal.
//
// In cap mode it flushes the notice ITSELF, inside recovered(), as a no-login session (no DK, not our wallet): the
// flush takes the free-first arm under profileRefV2(bare, pass), folds nothing and spends nothing. Left to
// pushProfile's deferred capFlush, a gateway failure would panic out of pushProfile, past its own recover (LIFO), and
// a clean skip would become a failed sign-out (the NWP-20260912-07 wedge). That deferred flush then finds the bracket
// closed and flushes nothing.
func writeSkipNotice(base, profile, pass string) {
	dk, v, ok := skipNoticeDK(base, profile, pass)
	if !ok {
		fmt.Println("push: skip notice not written (could not read)")
		return
	}
	if write, why := skipNoticeRecoveryLive(base, v); !write {
		fmt.Println("push: skip notice not written (" + why + ")")
		return
	}
	bare := profile
	if i := strings.IndexByte(profile, '#'); i >= 0 {
		bare = profile[:i]
	}
	js, err := json.Marshal(skipNoticeRecord{Phone: deviceLabel(), Time: skipNoticeNow().Unix() / 60 * 60})
	if err != nil {
		fmt.Println("push: skip notice not written (could not store)")
		return
	}
	body := base64.StdEncoding.EncodeToString(seal(dk, js))
	ref := skipNoticeRef(dk)
	if sealFencePublishBlocked("ref/" + ref) { // a delete on this phone moved the fence: publish nothing
		fmt.Println("push: skip notice not written (could not store)")
		return
	}
	if capMode() && isS3(base) {
		n := skipNoticeOpenBracket()
		if n == 0 {
			err = errors.New("no open cap bracket")
		} else {
			err = recovered(func() {
				capSetSessionAttr(bare, pass, nil, true) // a no-login session: the free arm, no fold, no spend
				putRef(base, ref, body)
				capFlush(n) // flushed here, under recovered: a gateway failure must not escape pushProfile
			})
		}
	} else {
		err = recovered(func() { putRef(base, ref, body) })
	}
	if err != nil {
		fmt.Println("push: skip notice not written (could not store)")
		return
	}
	fmt.Println("push: skip notice written")
}

// skipNoticeShownInfo keys the shown record's address: hex(HMAC-SHA256(dk, "nowhere-skip-notice-shown-v1")).
//
// ⚠ AN INFERENCE, NOT STATED BY CHESTER. h50 #6 says only that a sign-in "records that it showed it", not where. The
// notice's own ref is leased under the identity that wrote it (the old passphrase's profileRefV2), so the holder rule
// (nowhere-cloud AGENTS.md) stops a sign-in under the new passphrase from overwriting or deleting it. A second
// DK-keyed ref, leased under the current identity, needs no new authority. The store copy of the notice is left as
// it is: deleting it under the old identity is the open inference h50 #6 names.
const skipNoticeShownInfo = "nowhere-skip-notice-shown-v1"

// skipNoticeShownRecord is the shown record's sealed body: the notice time it covers, nothing else.
type skipNoticeShownRecord struct {
	Time int64 `json:"time"` // the skipNoticeRecord.Time last shown (unix seconds, minute precision)
}

// skipNoticeShownRef is the shown record's fixed address, the leaseable 64-hex ref shape, keyed by the DK.
func skipNoticeShownRef(dk []byte) string {
	m := hmac.New(sha256.New, dk)
	m.Write([]byte(skipNoticeShownInfo))
	return hex.EncodeToString(m.Sum(nil))
}

// skipNoticeReadDK opens the profile's DK from its published bare vault under the CURRENT credential, never from the
// restore receipt (that is the skipping phone's path, skipNoticeDK). Any failure is an error; it never panics.
func skipNoticeReadDK(base, name, pass string, se []byte) (dk []byte, err error) {
	var v *vault
	var isV bool
	if err = recovered(func() { _, v, isV = readVaultHead(base, name, pass) }); err != nil {
		return nil, err
	}
	if !isV || v == nil {
		return nil, errors.New("no vault head")
	}
	if dk = openVaultDKSE(v, name, pass, se); dk == nil {
		return nil, errors.New("no slot opens")
	}
	return dk, nil
}

// skipNoticeOpenAt reads one DK-sealed JSON record at ref into into. Absent is (false, nil). A failed read, or a
// record that does not open or does not parse, is an error. getRefBytesStrict, so a cap 403 or a transport error is
// never read as absence.
func skipNoticeOpenAt(base, at string, dk []byte, into any) (present bool, err error) {
	var b []byte
	if err = recovered(func() { b, present = getRefBytesStrict(base, at) }); err != nil {
		return false, err
	}
	if !present {
		return false, nil
	}
	pt, ok := unwrap(dk, strings.TrimSpace(string(b)))
	if !ok {
		return true, errors.New("record does not open")
	}
	if err = json.Unmarshal(pt, into); err != nil {
		return true, err
	}
	return true, nil
}

// readSkipNotice answers the profile's skip notice and whether to show it: show only when a notice opens and its Time
// is later than the shown record's (or there is none). No notice is show=false with no error.
func readSkipNotice(base, name, pass string, se []byte) (rec skipNoticeRecord, show bool, err error) {
	dk, err := skipNoticeReadDK(base, name, pass, se)
	if err != nil {
		return rec, false, err
	}
	noticeAt := skipNoticeRef(dk)
	have, err := skipNoticeOpenAt(base, noticeAt, dk, &rec)
	if err != nil || !have {
		return skipNoticeRecord{}, false, err
	}
	var shown skipNoticeShownRecord
	if _, err = skipNoticeOpenAt(base, skipNoticeShownRef(dk), dk, &shown); err != nil {
		return skipNoticeRecord{}, false, err
	}
	show = rec.Time > shown.Time
	return rec, show, nil
}

// markSkipNoticeShown records notice time t as shown. It never lowers the time already there, and a shown record it
// cannot read or open writes nothing (no blind overwrite). It writes only the shown ref, never the notice's.
//
// In cap mode it opens its OWN bracket, as sealWalletDurable does: a daemon verb has no open bracket. The session is
// the current identity with walletNotOurs, so the flush spends, folds and publishes no wallet. Everything runs under
// recovered(): a gateway failure is an error, never a panic out of the daemon.
func markSkipNoticeShown(base, name, pass string, se []byte, t int64) error {
	dk, err := skipNoticeReadDK(base, name, pass, se)
	if err != nil {
		return err
	}
	sref := skipNoticeShownRef(dk)
	var cur skipNoticeShownRecord
	have, err := skipNoticeOpenAt(base, sref, dk, &cur)
	if err != nil {
		return err
	}
	if have && cur.Time >= t {
		return nil // already covers t: never write a lower time
	}
	if sealFencePublishBlocked("ref/" + sref) {
		return errors.New("seal fence blocks the shown record")
	}
	js, err := json.Marshal(skipNoticeShownRecord{Time: t})
	if err != nil {
		return err
	}
	body := base64.StdEncoding.EncodeToString(seal(dk, js))
	if capMode() && isS3(base) {
		return recovered(func() {
			n := capBegin()
			defer capEndBracket(n)
			capSetSessionAttr(name, pass, dk, true) // the session's own identity; walletNotOurs: no spend, no fold
			putRef(base, sref, body)
			capFlush(n)
		})
	}
	return recovered(func() { putRef(base, sref, body) })
}

// skipNoticeLabelForWire drops every control character (tab, LF, CR, DEL, C1 included) from the phone label, so the
// reply stays one line with one tab.
func skipNoticeLabelForWire(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
}

// skipNoticeSession is both verbs' gate: a complete live session that is neither a throwaway nor offline, asked by an
// app of the session's own Android user. Every refusal reads the same to the caller (blind rule).
func skipNoticeSession(conn net.Conn, dest string) (name, pass string, ok bool) {
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" || localOnlySession(dest) {
		return "", "", false
	}
	if !sessionCaller(conn, uid) {
		return "", "", false
	}
	return name, pass, true
}

// handleGetSkipNotice answers "GET-SKIP-NOTICE": "NOTICE <phone>\t<unix time>" for a notice later than the shown
// record, else NONE; a failed read is ERR. A refused caller gets NONE. One count line, no name and no label.
func handleGetSkipNotice(conn net.Conn, dest, base string) {
	name, pass, ok := skipNoticeSession(conn, dest)
	if !ok {
		fmt.Fprint(os.Stderr, "[logind] get-skip-notice: none\n")
		fmt.Fprint(conn, "NONE\n")
		return
	}
	loadFido2HmacEnv(dest) // a 2FA vault opens via the cached key hmac; a restarted daemon has an empty env
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	rec, show, err := readSkipNotice(base, name, pass, seFromSession(dest))
	switch {
	case err != nil:
		fmt.Fprint(os.Stderr, "[logind] get-skip-notice: err\n")
		fmt.Fprint(conn, "ERR\n")
	case show:
		fmt.Fprint(os.Stderr, "[logind] get-skip-notice: notice\n")
		fmt.Fprintf(conn, "NOTICE %s\t%d\n", skipNoticeLabelForWire(rec.Phone), rec.Time)
	default:
		fmt.Fprint(os.Stderr, "[logind] get-skip-notice: none\n")
		fmt.Fprint(conn, "NONE\n")
	}
}

// handleSkipNoticeShown answers "SKIP-NOTICE-SHOWN\n<unix time>\n": OK once the time is recorded shown, else ERR. The
// time line counts only with its LF (the NWP-20261119-29 strict-line rule), and is read before the session.
func handleSkipNoticeShown(conn net.Conn, r *bufio.Reader, dest, base string) {
	line, err := r.ReadString('\n')
	var t int64
	if err == nil {
		t, err = strconv.ParseInt(strings.TrimRight(line, "\r\n"), 10, 64)
	}
	if err != nil || t <= 0 {
		fmt.Fprint(os.Stderr, "[logind] skip-notice-shown: err\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	name, pass, ok := skipNoticeSession(conn, dest)
	if !ok {
		fmt.Fprint(os.Stderr, "[logind] skip-notice-shown: err\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	loadFido2HmacEnv(dest)
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	if err := markSkipNoticeShown(base, name, pass, seFromSession(dest), t); err != nil {
		fmt.Fprint(os.Stderr, "[logind] skip-notice-shown: err\n")
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprint(os.Stderr, "[logind] skip-notice-shown: ok\n")
	fmt.Fprint(conn, "OK\n")
}
