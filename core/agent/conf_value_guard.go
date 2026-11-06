package main

import (
	"errors"
	"fmt"
)

// nowhere.conf is shell source: nowhere_roamd.sh, nowhere_otad.sh, nowhere_mediad.sh and nowhere_login.sh each
// `.` it as root. A value that holds a shell metacharacter, whitespace or `~` would be executed or rewritten
// rather than stored, so the three conf writers refuse any such value before they read or write anything.

// errConfValueUnsafe is the error every refused conf value or key wraps. Its text never carries the value.
var errConfValueUnsafe = errors.New("conf value is not inert as a sourced assignment")

// confValueOK reports whether v is inert as the value of a sourced KEY=value line: every byte is one of
// A-Z a-z 0-9 . : / _ - + = %. The empty string is allowed (`S3_REGION=` is inert). `~` is refused because a
// POSIX shell tilde-expands it at the start of a value or after a `:`.
func confValueOK(v string) bool {
	for i := 0; i < len(v); i++ {
		c := v[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '.', c == ':', c == '/', c == '_', c == '-', c == '+', c == '=', c == '%':
		default:
			return false
		}
	}
	return true
}

// confKeyOK reports whether k is a conf variable name this agent writes: ^[A-Z0-9_]+$.
func confKeyOK(k string) bool {
	if k == "" {
		return false
	}
	for i := 0; i < len(k); i++ {
		c := k[i]
		if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// checkConfValue returns nil for a safe value, else an error wrapping errConfValueUnsafe that names the field
// and never the value.
func checkConfValue(field, v string) error {
	if !confValueOK(v) {
		return fmt.Errorf("%s: %w", field, errConfValueUnsafe)
	}
	return nil
}
