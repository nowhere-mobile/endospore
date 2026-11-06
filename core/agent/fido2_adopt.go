package main

import "errors"

// adoptFido2Key is the stranded phone's "Use your security key" (NWP-20261111-03, Q016 in
// docs/product-decisions.md). A key enrolled on ANOTHER handset drops the head's pass slot, so this phone's
// session -- signed in by passphrase alone -- can no longer open the head it seals to, and every seal refuses.
// Its first exit is to assert the key here and adopt it the way sign-in does, so the session saves again.
//
// fido2-hmac (sign-in) asserts any fido2 slot of the head and prints the hmac WITHOUT checking that it opens
// one: the restore that follows proves it. An adopt has no such follow-on; its only proof would be the next
// seal, which is exactly what a revoked or re-wrapped slot would refuse. So the hmac is proven here against
// the CURRENT stored head before anything is staged or printed -- through the fido2 rung only, never
// openVaultDK: its pass rung would let a phone whose passphrase still opens the head read as "the key
// adopted", and its fido2 rung reads the process env, which this must not set.
//
// On success the non-secret slot spec is staged as .fido2slots.pre (roamd promotes it, and writes .fido2hmac
// from the printed hmac); on any failure nothing is staged, and a spec that cannot be staged returns its error
// and no hmac (NWP-20261112-15). No error names the profile or carries the hmac.
func adoptFido2Key(base, name, pass, stateDir string) ([]byte, error) {
	head := getRef(base, headKey(base, name, pass))
	if head == "" {
		return nil, errors.New("no profile")
	}
	v, isV := parseVault(getHeadBlob(base, head))
	if !isV {
		return nil, errors.New("not a vault")
	}
	slots := listFido2Slots(v)
	if len(slots) == 0 {
		return nil, errors.New("no security key enrolled on this profile")
	}
	h, err := assertAnySlot(slots)
	if err != nil {
		return nil, err
	}
	if fido2DKWith(v, deriveKey(name, pass), h) == nil {
		return nil, errors.New("the key did not unlock this profile")
	}
	if err := stashFido2SlotsPre(stateDir, slots); err != nil {
		return nil, err
	}
	return h, nil
}
