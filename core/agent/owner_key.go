package main

import (
	"bufio"
	"crypto/ecdh"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/hkdf"
)

// The device-owner telephony key (NWP-20260928-01). Chester, 2026-09-27 (docs/product-decisions.md, "how the
// unbound SIM's owner inbox is built"): "A random keypair held by the agent, its private half wrapped under a key
// from the owner passphrase (own salt). After verify the agent opens items with the existing seal code. A passphrase
// change is a rewrap. Devices enrolled before the update get their key at the next owner verify; a forgotten
// passphrase makes the inbox unreadable." And on 2026-09-28: on a StrongBox phone the wrap is also tied to
// StrongBox, so a copied key file cannot be guessed against off the phone.
//
// The keypair is X25519, the same as a profile's telephony key, so sealTelItem/openTelItem work unchanged. Its
// private half is wrapped (wrap(), AES-256-GCM) under kekOwner: Argon2id over the owner passphrase with a random
// salt of its own -- never owner.conf's salt, and never the verifier's construction, so the wrap key can never equal
// the FP3's stored verifier -- mixed through HKDF with the StrongBox pepper the gate computes on a StrongBox phone.
//
// The gate chooser mints it at every owner enrol (OWNER-KEY-NEW) and ensures it at every successful owner verify
// (OWNER-KEY-ENSURE), which is the heal for a device enrolled before this existed. Nothing is sealed to it until the
// seal-to-owner slice. NWP-20261021-11: OWNER-KEY-REWRAP is the passphrase change -- it re-wraps the same private
// half under the new passphrase and writes a v2 file holding both wrappings, until an ENSURE that opens the new one
// prunes the old. It persists beside bindings.conf: key material, not a record of any call or message.

// ownerKeyPath is the key file: persistent /data/nowhere (nowhere_data_file), not the state tmpfs. A var for tests.
var ownerKeyPath = "/data/nowhere/owner-key"

// ownerKeyMu serializes the owner-key verbs. Lock order: ownerKeyMu, then telMu (the publish renames under telMu).
// Nothing that holds telMu or sessionMu takes ownerKeyMu.
var ownerKeyMu sync.Mutex

const (
	ownerKeyHeader   = "nowhere-owner-key v1"
	ownerKeyHeaderV2 = "nowhere-owner-key v2"
	ownerKDFTime     = 3         // Argon2id passes: RFC 9106's 64 MiB profile, not the agent's t=1 house setting,
	ownerKDFMemKiB   = 64 * 1024 // because this file can be taken offline on a phone with no StrongBox
	ownerKDFThreads  = 4
	ownerSaltLen     = 32
	ownerPepperLen   = 32
	ownerPassMax     = 1024
)

// ownerKEKRuns counts kekOwner calls, so a test can see that an operation derived (or did not).
var ownerKEKRuns atomic.Int64

// Seams for tests: the caller's uid, and the publishing rename.
var (
	ownerPeerUID   = peerUID
	ownerKeyRename = os.Rename
)

// ownerKeyCmd reports whether handleOwnerKey serves a verb.
func ownerKeyCmd(name string) bool {
	return name == "OWNER-KEY-NEW" || name == "OWNER-KEY-ENSURE" || name == "OWNER-KEY-REWRAP"
}

// ownerCallerOK admits only the gate chooser in user 0: an app uid (at least 10000) whose appId is the pinned
// chooser's -- which also keeps it below the per-user offset, since the pin is an appId. A roamed session's chooser
// shares that appId (and its SELinux domain) but not user 0, so it is refused. Only root skips the accept-time pin
// (main.go, `uc.Uid != 0`); a system or shell uid is pin-checked like any peer, but trust-on-first-use pins it if it
// is the first non-root peer after the daemon starts, and a failed peerUID is -1, which an unpinned daemon's -1 would
// match. The floor refuses all three. pinnedChooserApp is read last, so a root peer never reads it while the accept
// loop may still be pinning.
func ownerCallerOK(uid int) bool {
	return uid >= 10000 && uid < 100000 && uid == pinnedChooserApp
}

// handleOwnerKey serves OWNER-KEY-NEW, OWNER-KEY-ENSURE and OWNER-KEY-REWRAP:
//
//	"<verb>\nv1\n<pepper: std base64 of 32 bytes, or ->\n<pass: std base64 of the UTF-8 owner passphrase>\n"
//
// and, for OWNER-KEY-REWRAP (NWP-20261021-11), the old pair then the new pair:
//
//	"OWNER-KEY-REWRAP\nv1\n<old pepper>\n<old pass>\n<new pepper>\n<new pass>\n"
//
// The "v1" line comes first so an older agent, which does not know the verb and falls through to the legacy login,
// takes "v1" as the profile passphrase and never sees the owner's. The reply is one line: OK | CREATED | REPLACED |
// REPAIRED | NOKEY | WRONG | DENIED | ERR request | ERR mode | ERR version | ERR io (NOKEY and WRONG are the
// rewrap's alone). A caller that is not the user-0 gate is refused
// before the request is read, and the refusal never depends on whether a key exists.
func handleOwnerKey(conn net.Conn, r *bufio.Reader, name string) {
	if !ownerCallerOK(ownerPeerUID(conn)) {
		fmt.Fprint(os.Stderr, "[logind] owner-key refused (caller is not the user-0 gate)\n")
		fmt.Fprint(conn, "DENIED\n")
		return
	}
	var oldPepper, oldPass, pepper, pass []byte
	var err error
	if name == "OWNER-KEY-REWRAP" {
		oldPepper, oldPass, pepper, pass, err = readOwnerKeyRewrapRequest(r)
	} else {
		pepper, pass, err = readOwnerKeyRequest(r)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] owner-key bad request (%v)\n", err)
		fmt.Fprint(conn, "ERR request\n")
		return
	}
	reply := func() string {
		ownerKeyMu.Lock()
		defer ownerKeyMu.Unlock()
		if name == "OWNER-KEY-REWRAP" {
			return ownerKeyRewrap(oldPepper, oldPass, pepper, pass)
		}
		return ownerKeyOp(name, pepper, pass)
	}()
	clear(oldPass)
	clear(oldPepper)
	clear(pass)
	clear(pepper)
	fmt.Fprintf(conn, "%s\n", reply) // after the unlock: a caller slow to read never holds ownerKeyMu
}

// readOwnerKeyRequest reads the three request lines. The errors name a field, never its value.
func readOwnerKeyRequest(r *bufio.Reader) (pepper, pass []byte, err error) {
	l, err := readLines(r, 3)
	if err != nil {
		return nil, nil, err
	}
	if l[0] != "v1" {
		return nil, nil, errors.New("unknown request version")
	}
	return readOwnerSecretPair(l[1], l[2], "")
}

// readOwnerKeyRewrapRequest reads the five rewrap request lines: the version, then the old pair, then the new pair.
func readOwnerKeyRewrapRequest(r *bufio.Reader) (oldPepper, oldPass, newPepper, newPass []byte, err error) {
	l, err := readLines(r, 5)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	if l[0] != "v1" {
		return nil, nil, nil, nil, errors.New("unknown request version")
	}
	if oldPepper, oldPass, err = readOwnerSecretPair(l[1], l[2], "old "); err != nil {
		return nil, nil, nil, nil, err
	}
	if newPepper, newPass, err = readOwnerSecretPair(l[3], l[4], "new "); err != nil {
		clear(oldPepper)
		clear(oldPass)
		return nil, nil, nil, nil, err
	}
	return oldPepper, oldPass, newPepper, newPass, nil
}

// readOwnerSecretPair validates one pepper line and one passphrase line. which is "" or "old " / "new ", so an error
// names the field, never its value.
func readOwnerSecretPair(pepperLine, passLine, which string) (pepper, pass []byte, err error) {
	if pepperLine != "-" {
		if pepper, err = base64.StdEncoding.DecodeString(pepperLine); err != nil || len(pepper) != ownerPepperLen {
			return nil, nil, errors.New("bad " + which + "pepper field")
		}
	}
	pass, err = base64.StdEncoding.DecodeString(passLine)
	if err != nil || len(pass) == 0 || len(pass) > ownerPassMax {
		clear(pepper)
		return nil, nil, errors.New("bad " + which + "secret field")
	}
	return pepper, pass, nil
}

type ownerKeyState int

const (
	ownerKeyAbsent ownerKeyState = iota
	ownerKeyValid
	ownerKeyNewer
	ownerKeyUnreadable
)

// ownerWrap is one wrapping of the owner key's private half: its own salt and the wrap() output.
type ownerWrap struct {
	salt    []byte
	wrapped string
}

// ownerKeyFile is a parsed v1 or v2 key file. pepper is "none" or "strongbox"; salt and wrapped are the NEW (first)
// wrapping. old is a v2 file's other wrapping, the one the passphrase before the last rewrap opens; nil for v1.
type ownerKeyFile struct {
	pub, pepper, wrapped string
	salt                 []byte
	old                  *ownerWrap
}

// wraps lists the file's wrappings, the new first.
func (f ownerKeyFile) wraps() []ownerWrap {
	ws := []ownerWrap{{f.salt, f.wrapped}}
	if f.old != nil {
		ws = append(ws, *f.old)
	}
	return ws
}

// readOwnerKey classifies the key file. A read error other than "absent" is returned as an error: a file we could
// not read is never replaced. A header naming a version above v2 is NEWER and is kept (an older agent after a
// rollback must not destroy a key the newer build can open). Anything else that is not exactly the v1 grammar or the
// v2 grammar (NWP-20261021-11: v1 plus old.salt= and old.wrapped=) is UNREADABLE.
func readOwnerKey() (ownerKeyFile, ownerKeyState, error) {
	b, err := os.ReadFile(ownerKeyPath)
	if errors.Is(err, os.ErrNotExist) {
		return ownerKeyFile{}, ownerKeyAbsent, nil
	}
	if err != nil {
		return ownerKeyFile{}, ownerKeyAbsent, err
	}
	s := string(b)
	first, _, _ := strings.Cut(s, "\n")
	if v, ok := strings.CutPrefix(first, "nowhere-owner-key v"); ok {
		if n, e := strconv.Atoi(v); e == nil && n > 2 {
			return ownerKeyFile{}, ownerKeyNewer, nil
		}
	}
	bad := ownerKeyFile{}
	if !strings.HasSuffix(s, "\n") || strings.Contains(s, "\r") {
		return bad, ownerKeyUnreadable, nil
	}
	l := strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	if !(len(l) == 5 && l[0] == ownerKeyHeader) && !(len(l) == 7 && l[0] == ownerKeyHeaderV2) {
		return bad, ownerKeyUnreadable, nil
	}
	var f ownerKeyFile
	var ok bool
	if f.pub, ok = strings.CutPrefix(l[1], "pub="); !ok || decodedLen(f.pub) != x25519KeyLen {
		return bad, ownerKeyUnreadable, nil
	}
	if f.pepper, ok = strings.CutPrefix(l[2], "pepper="); !ok || (f.pepper != "none" && f.pepper != "strongbox") {
		return bad, ownerKeyUnreadable, nil
	}
	nw, ok := parseOwnerWrap(l[3], l[4], "")
	if !ok {
		return bad, ownerKeyUnreadable, nil
	}
	f.salt, f.wrapped = nw.salt, nw.wrapped
	if len(l) == 7 {
		ow, ok := parseOwnerWrap(l[5], l[6], "old.")
		if !ok {
			return bad, ownerKeyUnreadable, nil
		}
		f.old = &ow
	}
	return f, ownerKeyValid, nil
}

// parseOwnerWrap reads one wrapping's two lines, "<prefix>salt=" and "<prefix>wrapped=".
func parseOwnerWrap(saltLine, wrappedLine, prefix string) (ownerWrap, bool) {
	saltB64, ok := strings.CutPrefix(saltLine, prefix+"salt=")
	if !ok {
		return ownerWrap{}, false
	}
	salt, err := base64.StdEncoding.DecodeString(saltB64)
	if err != nil || len(salt) != ownerSaltLen {
		return ownerWrap{}, false
	}
	// wrap() output: nonce(12) || ciphertext(32) || tag(16)
	wrapped, ok := strings.CutPrefix(wrappedLine, prefix+"wrapped=")
	if !ok || decodedLen(wrapped) != telNonceLen+x25519KeyLen+16 {
		return ownerWrap{}, false
	}
	return ownerWrap{salt, wrapped}, true
}

// decodedLen is the length of a std-base64 string's decoding, or -1 if it does not decode.
func decodedLen(s string) int {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return -1
	}
	return len(b)
}

// kekOwner derives the key that wraps the owner key's private half. It never goes through deriveKey, whose cache is
// keyed by the plaintext secret, and none of the agent's other KDFs takes a random salt.
func kekOwner(pass, salt, pepper []byte) []byte {
	ownerKEKRuns.Add(1)
	k := argon2.IDKey(pass, salt, ownerKDFTime, ownerKDFMemKiB, ownerKDFThreads, 32)
	defer clear(k)
	info := "pepper=none"
	ikm := k
	if pepper != nil {
		info = "pepper=strongbox"
		ikm = append(append(make([]byte, 0, len(k)+len(pepper)), k...), pepper...)
		defer clear(ikm)
	}
	kek := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, ikm, []byte("nowhere-owner-kek-v1"), []byte(info)), kek); err != nil {
		panic(err) // hkdf over a fixed reader never short-reads 32 bytes
	}
	return kek
}

// ownerKeyOpen unwraps the private half of a VALID file's NEW wrapping, and returns it with the public key it derives.
func ownerKeyOpen(f ownerKeyFile, pass, pepper []byte) (priv []byte, pub string, ok bool) {
	return ownerWrapOpen(ownerWrap{f.salt, f.wrapped}, pass, pepper)
}

// ownerWrapOpen unwraps the private half from one wrapping: one kekOwner derivation.
func ownerWrapOpen(w ownerWrap, pass, pepper []byte) (priv []byte, pub string, ok bool) {
	kek := kekOwner(pass, w.salt, pepper)
	defer clear(kek)
	priv, ok = unwrap(kek, w.wrapped)
	if !ok {
		return nil, "", false
	}
	k, err := ecdh.X25519().NewPrivateKey(priv)
	if err != nil {
		clear(priv)
		return nil, "", false
	}
	return priv, base64.StdEncoding.EncodeToString(k.PublicKey().Bytes()), true
}

// ownerKeyOpenAny tries each wrapping in order (one kekOwner derivation per wrapping tried) and returns the private
// half, its public key and the index of the wrapping that opened.
func ownerKeyOpenAny(ws []ownerWrap, pass, pepper []byte) (priv []byte, pub string, i int, ok bool) {
	for i, w := range ws {
		if priv, pub, ok = ownerWrapOpen(w, pass, pepper); ok {
			return priv, pub, i, true
		}
	}
	return nil, "", 0, false
}

// ownerKeyOp runs one verb under ownerKeyMu and returns the reply.
func ownerKeyOp(verb string, pepper, pass []byte) string {
	if verb == "OWNER-KEY-NEW" {
		_, statErr := os.Stat(ownerKeyPath)
		if err := ownerKeyMint(pass, pepper); err != nil {
			return ownerKeyIOErr(err)
		}
		ownerKeyLog("minted at enrol")
		if statErr == nil {
			return "REPLACED"
		}
		return "CREATED"
	}
	f, st, err := readOwnerKey()
	if err != nil {
		return ownerKeyIOErr(err)
	}
	mode := "none"
	if pepper != nil {
		mode = "strongbox"
	}
	replace := func(why, reply string) string {
		if err := ownerKeyMint(pass, pepper); err != nil {
			return ownerKeyIOErr(err)
		}
		ownerKeyLog(why)
		return reply
	}
	switch st {
	case ownerKeyAbsent:
		return replace("created", "CREATED")
	case ownerKeyUnreadable:
		return replace("replaced (unreadable file)", "REPLACED")
	case ownerKeyNewer:
		ownerKeyLog("kept a newer-format file")
		return "ERR version"
	}
	if f.pepper == "strongbox" && mode == "none" {
		ownerKeyLog("refused a pepperless request for a StrongBox key") // never downgrade
		return "ERR mode"
	}
	if f.pepper == "none" && mode == "strongbox" {
		return replace("replaced (pepper added)", "REPLACED")
	}
	priv, pub, i, ok := ownerKeyOpenAny(f.wraps(), pass, pepper)
	if !ok {
		// A verify has just admitted this passphrase, so nobody the verify admits can ever open this key: damage,
		// tampering, an enrol whose NEW never arrived, a cleared chooser data dir. Keeping it would lose every
		// unbound arrival until a factory reset; the 2026-09-27 decision accepts that only for a forgotten one.
		return replace("replaced (did not open)", "REPLACED")
	}
	clear(priv)
	if i > 0 {
		// NWP-20261021-11: only the OLD wrapping of a v2 file opened. The rewrap has not landed in owner.conf, or
		// this is the verify that preceded it and its ENSURE arrived after the rewrap. Write nothing: pruning to
		// this wrapping would drop the new one, and the next ENSURE under the new passphrase would replace the key.
		return "OK"
	}
	if f.old != nil {
		// The NEW wrapping of a v2 file opened: the change has landed, so the old wrapping goes.
		if err := ownerKeyWrite(ownerKeyFileBody(pub, f.pepper, f.salt, f.wrapped)); err != nil {
			return ownerKeyIOErr(err)
		}
		ownerKeyLog("pruned the old wrapping")
		return "REPAIRED"
	}
	if pub == f.pub {
		return "OK" // nothing written
	}
	// wrap() carries no AAD, so the wrapped half is authentic and pub= is not: rewrite pub= from it.
	if err := ownerKeyWrite(ownerKeyFileBody(pub, f.pepper, f.salt, f.wrapped)); err != nil {
		return ownerKeyIOErr(err)
	}
	ownerKeyLog("public half repaired")
	return "REPAIRED"
}

// ownerKeyMint makes a new keypair, wraps its private half under a fresh salt, and publishes the file.
func ownerKeyMint(pass, pepper []byte) error {
	pub, priv, err := newTelephonyKeypair()
	if err != nil {
		return err
	}
	defer clear(priv)
	salt := randBytes(ownerSaltLen)
	kek := kekOwner(pass, salt, pepper)
	defer clear(kek)
	mode := "none"
	if pepper != nil {
		mode = "strongbox"
	}
	return ownerKeyWrite(ownerKeyFileBody(pub, mode, salt, wrap(kek, priv)))
}

// ownerPepperMode is the file's pepper mode a request's pepper asks for.
func ownerPepperMode(pepper []byte) string {
	if pepper != nil {
		return "strongbox"
	}
	return "none"
}

// ownerKeyRewrap re-wraps the owner key's private half under a new passphrase (NWP-20261021-11) and publishes a v2
// file holding the new wrapping and the one the old passphrase opened, both of the same key, so the inbox opens under
// either until an ENSURE opens the new one. Nothing is written unless the reply is OK. The destructive replace stays
// ENSURE's alone: a wrong old passphrase is WRONG, an absent or unreadable file is NOKEY (the next ENSURE under the
// new passphrase creates a key). Every kekOwner derivation runs outside telMu; the caller holds ownerKeyMu.
func ownerKeyRewrap(oldPepper, oldPass, newPepper, newPass []byte) string {
	f, st, err := readOwnerKey()
	if err != nil {
		return ownerKeyIOErr(err)
	}
	switch st {
	case ownerKeyAbsent, ownerKeyUnreadable:
		ownerKeyLog("rewrap found no key")
		return "NOKEY"
	case ownerKeyNewer:
		ownerKeyLog("kept a newer-format file")
		return "ERR version"
	}
	// Never a pepperless wrapping on a StrongBox file, and no mode change through this verb: checked before any derivation.
	if ownerPepperMode(oldPepper) != f.pepper || ownerPepperMode(newPepper) != f.pepper {
		ownerKeyLog("refused a rewrap whose pepper does not match the key")
		return "ERR mode"
	}
	priv, pub, i, ok := ownerKeyOpenAny(f.wraps(), oldPass, oldPepper)
	if !ok {
		ownerKeyLog("rewrap refused (did not open)")
		return "WRONG"
	}
	defer clear(priv)
	salt := randBytes(ownerSaltLen)
	kek := kekOwner(newPass, salt, newPepper)
	defer clear(kek)
	body := ownerKeyFileBodyV2(pub, f.pepper, ownerWrap{salt, wrap(kek, priv)}, f.wraps()[i])
	if err := ownerKeyWrite(body); err != nil {
		return ownerKeyIOErr(err)
	}
	ownerKeyLog("rewrapped")
	return "OK"
}

func ownerKeyFileBodyV2(pub, pepper string, nw, old ownerWrap) string {
	return ownerKeyHeaderV2 + "\npub=" + pub + "\npepper=" + pepper + "\nsalt=" + base64.StdEncoding.EncodeToString(nw.salt) +
		"\nwrapped=" + nw.wrapped + "\nold.salt=" + base64.StdEncoding.EncodeToString(old.salt) + "\nold.wrapped=" + old.wrapped + "\n"
}

func ownerKeyFileBody(pub, pepper string, salt []byte, wrapped string) string {
	return ownerKeyHeader + "\npub=" + pub + "\npepper=" + pepper + "\nsalt=" + base64.StdEncoding.EncodeToString(salt) +
		"\nwrapped=" + wrapped + "\n"
}

// ownerKeyWrite publishes body at ownerKeyPath: a new 0600 temp file (O_EXCL, so a planted symlink is refused),
// synced, then renamed under telMu so a later slice can make "replace the key and drop what was sealed to the old
// one" one step for an arrival; then the directory is synced. A lost key file loses every unbound arrival until the
// next verify, so it is fsynced, as bindings.conf is (NWP-20260930-04). A missing directory is an error, not created.
// On any error the old file is left as it was.
func ownerKeyWrite(body string) error {
	dir := filepath.Dir(ownerKeyPath)
	tmp := filepath.Join(dir, ".owner-key.tmp")
	os.Remove(tmp)
	fh, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, werr := fh.WriteString(body)
	serr := fh.Sync()
	cerr := fh.Close()
	if err = errors.Join(werr, serr, cerr); err != nil {
		os.Remove(tmp)
		return err
	}
	underTelMu(func() { err = ownerKeyRename(tmp, ownerKeyPath) })
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if d, e := os.Open(dir); e == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// ownerKeyLog writes one class-only line: never a secret, a key, a salt, the file's contents, or the word the
// issue-report scrubber drops lines for (issueDropKeywords). The prefix is "owner-key " with no colon: the scrubber's
// reIssueKV reads "<...key...>: <word>" as a secret pair and would redact the class the line exists to report.
func ownerKeyLog(what string) { fmt.Fprintf(os.Stderr, "[logind] owner-key %s\n", what) }

// ownerKeyIOErr logs a failed read or write as its operation and errno, without the path: "<path>: <errno>" ends in
// "owner-key: " or ".owner-key.tmp: ", which the scrubber's reIssueKV would read as a secret pair, redacting the one
// word that says why.
func ownerKeyIOErr(err error) string {
	why := err.Error()
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.As(err, &pe):
		why = pe.Op + " " + pe.Err.Error()
	case errors.As(err, &le):
		why = le.Op + " " + le.Err.Error()
	}
	ownerKeyLog("write or read failed: " + why)
	return "ERR io"
}

// NWP-20260930-01: the owner-mode verbs -- the SIM bindings, the telephony pubkey lookup the binding screen uses, the
// gate notice's number setting, and since NWP-20261110-02 the bindings repair and the per-SIM mine mark -- are the
// gate's alone, like the owner-key verbs. The accept-time pin checks only the chooser's appId, which a roamed session's
// chooser shares along with its SELinux domain, and the chooser offers these verbs only in owner mode, which runs only
// in the user-0 gate. Unrefused, a roamed session could read every bound SIM's ICCID, bind a SIM so that its arrivals
// seal to a profile of its choosing, or unassign a SIM and delete its pending records. handleLogin checks before it
// takes sessionMu or reads a byte of the request, so a refusal never waits behind a login and never depends on the
// request.

// ownerModeCmd reports whether a verb is an owner-mode verb.
func ownerModeCmd(name string) bool {
	switch name {
	case "GET-TELPUB", "SET-BINDING", "GET-BINDINGS", "DELETE-BINDING", "GET-NOTICE-NUMBER", "SET-NOTICE-NUMBER",
		"REPAIR-BINDINGS", "SET-SIM-MINE":
		return true
	}
	return false
}

// refusedOwnerModeCaller answers DENIED, and reports true, for an owner-mode verb from any caller but the user-0 gate.
// The log line names neither the verb nor the caller.
func refusedOwnerModeCaller(conn net.Conn, name string) bool {
	if !ownerModeCmd(name) || ownerCallerOK(ownerPeerUID(conn)) {
		return false
	}
	fmt.Fprint(os.Stderr, "[logind] owner-mode verb refused (caller is not the user-0 gate)\n")
	fmt.Fprint(conn, "DENIED\n")
	return true
}

// storeConfigCmd reports whether a verb changes or probes the phone's store from a client-supplied request:
// SET-STORE and SET-STORE-MANAGED rewrite nowhere.conf and the live store env, TEST-STORE dials a client-supplied
// endpoint with client-supplied credentials. GET-STORE and PING-STORE only read, and are not listed.
func storeConfigCmd(name string) bool {
	switch name {
	case "SET-STORE", "SET-STORE-MANAGED", "TEST-STORE":
		return true
	}
	return false
}

// refusedStoreConfigCaller answers DENIED, and reports true, for a store-config verb from any caller but the user-0
// gate or root. Root stays admitted so an operator can re-point a dev device over adb; it can edit nowhere.conf
// anyway. The log line names neither the verb's arguments nor the caller.
func refusedStoreConfigCaller(conn net.Conn, name string) bool {
	if !storeConfigCmd(name) {
		return false
	}
	uid := ownerPeerUID(conn)
	if uid == 0 || ownerCallerOK(uid) {
		return false
	}
	fmt.Fprint(os.Stderr, "[logind] store-config verb refused (caller is not the user-0 gate)\n")
	fmt.Fprint(conn, "DENIED\n")
	return true
}

// NWP-20261024-04, NWP-20261031-12, NWP-20261118-15: twenty-four verbs have exactly one sender, user-0 gate code, and
// checked no caller. The accept-time pin admits the chooser's appId in EVERY user, and a roamed session's chooser
// shares it and the gate's SELinux domain, so only a check inside handleLogin tells the gate from a session. Each
// verb, its only sender, and what it did for a roamed caller:
//   - CLEAN-STORAGE: ChooserActivity.cleanUserStorage, after an accepted removeUser. roamd's cleanstorage removes the
//     per-user trees of ANY uid of 10 or more, the session's own under its running apps or a parked cold lock's.
//   - OTA-APPLY: the gate's preferred-time timer, screen-off trigger and the Install button, the first two only with
//     no session live. handleOtaApply and otad never check, and otad reboots the phone: a session loses all it has not sealed.
//   - BT-WIPE, BOOT-SWEEP: BootReceiver, at boot, in user 0. A roamed caller cleared the Bluetooth bonds and scrubbed
//     roam.log, or re-ran the boot-only sweep, mid-session.
//   - ACK-REAP: the reap watcher. A roamed caller retired a queued SWITCH, REAP or LOCK, so the gate never removed the
//     departed user and its cleartext CE stayed.
//   - CLEAR-COLDLOCK, CLAIM-COLDLOCK: the gate's login worker and its cold-lock wipe. A roamed caller made the daemon
//     forget a parked session's marker (CLAIM also drops .localsession), and the session could no longer resume.
//   - GET-GATE-ALARM: the gate's onResume. It reads AND removes the stashed alarm that rings on the gate (decided
//     2026-10-04), so a roamed caller consumed it.
//   - SET-OTA-AUTO, SET-OTA-TIME: the gate Settings switch and ChooserActivity.showOtaTimePicker. A roamed caller
//     turned automatic OS installs on or off (ota-auto) or moved the install time (ota-time).
//   - SET-SYNC-INTERVAL: ChooserActivity.showSyncIntervalPicker. A roamed caller changed the save cadence of every
//     profile (sync-interval).
//   - SEED-SSAID: the gate's sign-in, between createAndManageUser and startUserInBackground. A roamed caller started
//     a head-blob prefetch, made the daemon derive an SSAID userkey from a name and passphrase it chose, and had
//     roamd stage that seed in another user's system dir.
//   - GRANT-PERMS: ChooserActivity.provisionRoamedApps, in the gate's sign-in, after install-existing. roamd's grant
//     op ran for any uid it named, a parked cold lock's included; the login window closed early, mediad was
//     re-kicked, the tie finish started, and grantTail armed the boot-broadcast gate and ran seed-home, which
//     force-stops Launcher3.
//   - PREFETCH-ARM: ChooserActivity.startSyncStatusWatcher, user 0 only. A roamed caller armed the Tier-2 media
//     prefetch and re-kicked mediad against the gate's Wi-Fi and idle/charging judgement (#129), so on mobile data too.
//   - PREFETCH-DISARM: the same watcher. A roamed caller removed the arm flag, so the Tier-2 prefetch the gate had
//     armed parked at its next file boundary.
//   - REKEY-ARM: the same watcher. A roamed caller started the tied profile's background re-key off Wi-Fi or under
//     20% battery, against Chester's two conditions of 2026-10-08 (docs/tie-scope-keys.md §9).
//   - REKEY-DISARM: the same watcher. A roamed caller removed the arm flag, so a re-key the gate had armed stopped.
//   - REKEY-WAIT-WIFI: the same watcher. A roamed caller stopped an armed re-key and made the Tie screen say it waits
//     for Wi-Fi (wifi: no Wi-Fi, and the profile does not allow mobile data).
//   - REKEY-WAIT-NET: the same watcher. A roamed caller stopped an armed re-key and made the Tie screen say it waits
//     for a connection (net: no network at all).
//   - REKEY-WAIT-BATTERY: the same watcher. A roamed caller stopped an armed re-key and made the Tie screen say it
//     waits for battery (battery: under 20% and not charging).
//   - SAVE-NET-UNMETERED: the gate's slow tick while a session is live (NWP-20261201-03). A roamed caller claimed an
//     unmetered network and started an Only on Wi-Fi profile's periodic save on mobile data.
//   - SAVE-NET-METERED: the same tick. A roamed caller claimed a metered network and held an Only on Wi-Fi profile's
//     periodic saves back while the phone was on Wi-Fi.
//
// The rule is gateCallerOK (user 0, root included), NOT ownerCallerOK: the pinned appId is trust-on-first-use and can
// miss the gate, and these senders DROP the reply, so a gate wrongly refused would silently stop the reap and the boot
// wipe. Root and user 0 stay admitted, which is every real sender.
//
// Left out on purpose: POLL-REAP, GET-COLDLOCK, GET-COLDLOCK-PENDING and COLD-LOCK-STATUS only read. DROP-CACHES and
// EVICT-RECHECK run a probe whose verdict only the asking gate acts on. COLD-LOCK-ABORT is sent from the live roamed
// user and re-checks its uid against the live session. SILENCE-GATE-ALARM acts only on the stashed target.
// SET-GATE-ALARM is the session's own relay. OTA-APPLY-AFTER-LOGOFF refuses while a session exists. OTA-REFRESH only
// checks.

// gateOnlyCmd reports whether a verb is one that only user-0 gate code sends.
// EVICT-RECHECK-SAVED (NWP-20261106-12) is one: the wipe it licenses is the gate's.
// SIGNIN-SHOWN (NWP-20261106-07) is one: only the gate shows a sign-in failure, and a roamed session writing it would
// plant a failure the next gate report states as fact.
// SET-DEVICE-LABEL (NWP-20261114-24) is one: only the gate's first-run setup names the phone.
// DROP-SSAID (NWP-20261115-01) is one: only the user-0 gate abandons a sign-in's user, and a roamed caller would remove
// another user's SSAID files.
// RERUN-REAP (NWP-20261125-15) is one: only the gate re-runs a teardown, and a roamed caller could queue the removal of
// another user.
func gateOnlyCmd(name string) bool {
	switch name {
	case "CLEAN-STORAGE", "BOOT-SWEEP", "SET-DEVICE-LABEL", "BT-WIPE", "RERUN-REAP", "ACK-REAP", "DROP-SSAID", "CLEAR-COLDLOCK", "CLAIM-COLDLOCK", "GET-GATE-ALARM",
		"OTA-APPLY", "SIGNIN-SHOWN",
		"SET-OTA-AUTO", "SET-OTA-TIME", "SET-SYNC-INTERVAL", "SEED-SSAID", "EVICT-RECHECK-SAVED":
		return true
	case "GRANT-PERMS", "PREFETCH-ARM", "PREFETCH-DISARM",
		"REKEY-ARM", "REKEY-DISARM", "REKEY-WAIT-WIFI", "REKEY-WAIT-NET", "REKEY-WAIT-BATTERY":
		return true
	case "SAVE-NET-UNMETERED", "SAVE-NET-METERED":
		return true
	}
	return false
}

// refusedGateOnlyCaller answers DENIED, and reports true, for a gate-only verb from any caller outside user 0 (a
// failed peer read included). The log line names the verb and nothing else: no uid, no request line.
func refusedGateOnlyCaller(conn net.Conn, name string) bool {
	if !gateOnlyCmd(name) || gateCallerOK(ownerPeerUID(conn)) {
		return false
	}
	fmt.Fprintf(os.Stderr, "[logind] gate-only verb %q refused (caller is not in user 0)\n", name)
	fmt.Fprint(conn, "DENIED\n")
	return true
}
