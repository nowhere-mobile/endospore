package main

// seStateOf classifies a parsed vault: HARDENED, PASSONLY (a pass slot, not hardened), or OTHER. NWP-20261005-27 built it
// for the gate's SE-STATE (the sign-in offer); since NWP-20261006-09 SE-STATUS uses it (se_tie.go) and SE-STATE is gone.
func seStateOf(v *vault) string {
	if v.Hardened {
		return "HARDENED"
	}
	for _, s := range v.Slots {
		if s.Kind == "pass" {
			return "PASSONLY"
		}
	}
	return "OTHER"
}
