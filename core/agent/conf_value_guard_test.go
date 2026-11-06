package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestConfValueGuardTable(t *testing.T) {
	ok := []string{
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
		"https://s3.filebase.com:443/path",
		"auto",
		"eu-central-1",
		"my-bucket.v2",
		"AKIAIOSFODNN7EXAMPLE",
		"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY==",
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"",
		"https://api-beta.nowhere.mobile",
	}
	for _, v := range ok {
		if !confValueOK(v) {
			t.Errorf("refused a legitimate value of length %d", len(v))
		}
	}
	bad := []string{
		"a$(id)", "$HOME", "a`id`", "a;b", "a b", " a", "a\t", "a\nb", "a\rb", "a\\b", "a|b", "a&b",
		"'a'", "\"a\"", "~/x", "a:~b", "a#b", "a*", "a\xc3\xa9", "a\xc3", "a<b", "a>b", "a(b", "a)b",
		"a{b", "a}b", "a[b", "a]b", "a?b", "a!b", "a@b", "a,b", "a\x00b",
	}
	for _, v := range bad {
		if confValueOK(v) {
			t.Errorf("accepted %q", v)
		}
	}
}

func TestConfValueGuardWritersRefuse(t *testing.T) {
	const seed = "S3_ENDPOINT=old\nGATEWAY_URL=https://old.example\nNOWHERE_SYNC_INTERVAL=30\n"
	hostile := "x$(touch /nope)"
	good := [5]string{"https://e.example", "auto", "bkt", "AKIA1", "sec+/=="}
	cases := []struct {
		name  string
		write func() error
	}{
		{"managed", func() error { return writeManagedConf(hostile) }},
		{"upsert value", func() error { return upsertConfLine("GATEWAY_URL", hostile) }},
		{"upsert key", func() error { return upsertConfLine("GATEWAY_URL;x", "ok") }},
		{"upsert empty key", func() error { return upsertConfLine("", "ok") }},
		{"upsert lower key", func() error { return upsertConfLine("gateway", "ok") }},
	}
	for i := range good {
		i := i
		cases = append(cases, struct {
			name  string
			write func() error
		}{"store field " + string(rune('0'+i)), func() error {
			v := good
			v[i] = hostile
			return writeStoreConf(v[0], v[1], v[2], v[3], v[4])
		}})
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			conf := tempConf(t, seed)
			err := c.write()
			if !errors.Is(err, errConfValueUnsafe) {
				t.Fatalf("err = %v, want errConfValueUnsafe", err)
			}
			if strings.Contains(err.Error(), "touch") {
				t.Fatalf("error carries the value: %v", err)
			}
			got, rerr := os.ReadFile(conf)
			if rerr != nil || string(got) != seed {
				t.Fatalf("conf changed: %q, %v", got, rerr)
			}
			if _, serr := os.Stat(conf + ".tmp"); !os.IsNotExist(serr) {
				t.Fatalf("temp left behind: %v", serr)
			}
		})
	}
	t.Run("error names the field", func(t *testing.T) {
		tempConf(t, seed)
		err := writeStoreConf("e", "r", "b", "a", hostile)
		if err == nil || !strings.Contains(err.Error(), "S3_SECRET_KEY") {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestConfValueGuardSourcedRoundTrip(t *testing.T) {
	var shells []string
	for _, n := range []string{"bash", "sh", "dash", "mksh"} {
		if p, err := exec.LookPath(n); err == nil {
			shells = append(shells, p)
		}
	}
	if len(shells) == 0 {
		t.Skip("no shell found")
	}
	t.Logf("shells: %v", shells)
	const script = ". \"$1\"; printf '%s\\n' \"$S3_ENDPOINT\" \"$S3_REGION\" \"$S3_BUCKET\" \"$S3_ACCESS_KEY\" \"$S3_SECRET_KEY\" \"$GATEWAY_URL\""
	sets := [][6]string{
		{"=x", "a:=b", "%2F", "+/=", "https://s3.example.com:443/p-q_r.s%20", "https://gw.example/a=b"},
		{"ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz0123456789", "-x-", "/", ":a:", "a="},
		{"", "", "b", "a", "s", ""},
	}
	// Every allow-listed byte at the start, the middle and the end of a value.
	const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:/_-+=%"
	var vals []string
	for i := 0; i < len(allowed); i++ {
		b := allowed[i : i+1]
		vals = append(vals, b+"x", "x"+b+"x", "x"+b, b)
	}
	for len(vals)%6 != 0 {
		vals = append(vals, "pad")
	}
	for i := 0; i < len(vals); i += 6 {
		var w [6]string
		copy(w[:], vals[i:i+6])
		sets = append(sets, w)
	}
	for _, shell := range shells {
		t.Run(shell, func(t *testing.T) {
			conf := tempConf(t, "")
			for _, w := range sets {
				if err := writeStoreConf(w[0], w[1], w[2], w[3], w[4]); err != nil {
					t.Fatal(err)
				}
				if err := upsertConfLine("GATEWAY_URL", w[5]); err != nil {
					t.Fatal(err)
				}
				out, err := exec.Command(shell, "-c", script, "x", conf).Output()
				if exp := strings.Join(w[:], "\n") + "\n"; err != nil || string(out) != exp {
					t.Fatalf("round trip: got %q want %q, %v", out, exp, err)
				}
			}
			// Control: a hand-written command substitution does run, so a clean round trip is not a harness that never ran.
			if err := os.WriteFile(conf, []byte("S3_BUCKET=$(printf ran)\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			out, err := exec.Command(shell, "-c", script, "x", conf).Output()
			if err != nil || !strings.Contains(string(out), "ran") {
				t.Fatalf("control did not execute: %q, %v", out, err)
			}
		})
	}
}
