package main

import "testing"

// NWP-20261014-48: pins inheritedContext, the decision inside inheritSELinuxLevel (DIA-20260808-02).
func TestInheritedContext(t *testing.T) {
	const cat = "u:object_r:app_data_file:s0:c208,c256,c523,c768"
	cases := []struct {
		name, pctx, cctx, want string
		ok                     bool
	}{
		{"parent without categories, different child", "u:object_r:system_data_file:s0", "u:object_r:app_data_file:s0", "", false},
		{"empty parent", "", "u:object_r:app_data_file:s0", "", false},
		{"child already categorised", cat, "u:object_r:app_data_file:s0:c1,c2", "", false},
		{"identical", cat, cat, "", false},
		{"bare child under categorised parent", cat, "u:object_r:app_data_file:s0", cat, true},
	}
	for _, c := range cases {
		got, ok := inheritedContext(c.pctx, c.cctx)
		if got != c.want || ok != c.ok {
			t.Errorf("%s: got (%q, %v), want (%q, %v)", c.name, got, ok, c.want, c.ok)
		}
	}
}
