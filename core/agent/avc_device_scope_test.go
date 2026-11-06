package main

import (
	"reflect"
	"strings"
	"testing"
)

const planted = "com.example.planted"

// dn-1105 #1: a gate report keeps a denial by its SOURCE domain, drops app=, and keeps roamd's own children.
var deviceScopeCases = []struct {
	name string
	in   string
	want string // "" = dropped
}{
	{"app on a nowhere_ target", `avc: denied { read } for comm="x" name="m" scontext=u:r:untrusted_app:s0:c1,c2 tcontext=u:object_r:nowhere_media_file:s0 tclass=file app=` + planted, ""},
	{"roamd child chown", `avc: denied { chown } for comm="chown" scontext=u:r:endospore_priv:s0 tcontext=u:object_r:system_data_file:s0 tclass=file`, `avc: denied { chown } for comm="chown" scontext=u:r:endospore_priv:s0 tcontext=u:object_r:system_data_file:s0 tclass=file`},
	{"update_engine", `avc: denied { read } scontext=u:r:update_engine:s0 tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:update_engine:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"nowhere", `avc: denied { read } scontext=u:r:nowhere:s0 tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:nowhere:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"nowhere_chooser", `avc: denied { read } scontext=u:r:nowhere_chooser:s0 tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:nowhere_chooser:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"endospore_mediad", `avc: denied { read } scontext=u:r:endospore_mediad:s0 tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:endospore_mediad:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"su", `avc: denied { read } scontext=u:r:su:s0 tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:su:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"surfaceflinger", `avc: denied { read } scontext=u:r:surfaceflinger:s0 tcontext=u:object_r:nowhere_x:s0 tclass=file`, ""},
	{"near miss nowhere_media", `avc: denied { read } scontext=u:r:nowhere_media:s0 tcontext=u:object_r:x:s0 tclass=file`, ""},
	{"kept domain with app=", `avc: denied { read } scontext=u:r:su:s0 tcontext=u:object_r:x:s0 tclass=file app=` + planted, `avc: denied { read } scontext=u:r:su:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"kept domain, app= mid-line", `avc: denied { read } scontext=u:r:su:s0 app=` + planted + ` tcontext=u:object_r:x:s0 tclass=file`, `avc: denied { read } scontext=u:r:su:s0 tcontext=u:object_r:x:s0 tclass=file`},
	{"no scontext", `avc: denied { read } tcontext=u:object_r:update_engine:s0 comm="nowhere_x" tclass=file`, ""},
	{"target is a kept domain", `avc: denied { read } scontext=u:r:untrusted_app:s0 tcontext=u:r:su:s0 tclass=file`, ""},
}

func TestDeviceScopeDenials(t *testing.T) {
	var in, want []string
	for _, c := range deviceScopeCases {
		in = append(in, c.in)
		if c.want != "" {
			want = append(want, c.want)
		}
		if got := deviceScopeDenials([]string{c.in}); (c.want == "") != (len(got) == 0) || (len(got) == 1 && got[0] != c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	if got := deviceScopeDenials(in); !reflect.DeepEqual(got, want) {
		t.Errorf("order/set over the whole table:\n got %q\nwant %q", got, want)
	}
}

func TestDeviceScopeDenialsEndToEnd(t *testing.T) {
	var in, want []string
	for _, c := range deviceScopeCases {
		in = append(in, c.in)
		if c.want != "" {
			want = append(want, c.want)
		}
	}
	// the report's scrub rewrites comm="..." to comm="<name>"; that is not this rule's concern.
	for i := range want {
		want[i] = strings.Replace(want[i], `comm="chown"`, `comm="<name>"`, 1)
	}
	stubAvc(t, [][]string{{"/test/logcat"}}, map[string]string{"/test/logcat": strings.Join(in, "\n") + "\n"}, nil)

	lines := buildIssueReport("", true, "", nil, nil).Logs["avc"]
	avc := strings.Join(lines, "\n")
	var denials []string
	for _, ln := range lines {
		if strings.Contains(ln, "avc: denied") {
			denials = append(denials, ln)
		}
	}
	if !reflect.DeepEqual(denials, want) {
		t.Errorf("device-scope avc denials:\n got %q\nwant %q\nsection:\n%s", denials, want, avc)
	}
	if strings.Contains(avc, "app=") || strings.Contains(avc, planted) {
		t.Errorf("device-scope avc section carries an app: %s", avc)
	}

	all := strings.Join(buildIssueReport("sess", false, "", nil, nil).Logs["avc"], "\n")
	if n := strings.Count(all, "avc: denied"); n != len(in) {
		t.Errorf("session scope kept %d of %d denials", n, len(in))
	}
	if !strings.Contains(all, "app=") {
		t.Errorf("session scope lost its app= field")
	}
}
