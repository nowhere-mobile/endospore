package main

import (
	"errors"
	"os"
	"strings"
	"testing"
)

// NWP-20261110-01: the rebuilt mark and the mine records of bindings.conf (bindings_check.go "THE REBUILT MARK",
// Q031 in docs/product-decisions.md). A rewrite of a flawed file marks it rebuilt, and in a rebuilt file a SIM that no
// good line names is UNRESOLVED until it is bound or marked mine, never the device owner's.

// rebuiltGood is a good line for a SIM bound to one fake owner.
func rebuiltGood(iccid, ref string) string {
	return serializeLine(simBinding{SubID: 1, ICCID: iccid, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{ProfileRef: ref, TelPub: "pub" + ref}}})
}

func rebuiltPut(t *testing.T, text string) {
	t.Helper()
	if err := os.WriteFile(bindingsPath, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func rebuiltRead(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(bindingsPath)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func rebuiltClass(t *testing.T, iccid string) lineClass {
	t.Helper()
	telMu.Lock()
	defer telMu.Unlock()
	_, c := arrivalLine(-1, iccid, bootNowMs())
	return c
}

func TestBindingsRebuiltParse(t *testing.T) {
	st := parseBindingsText("v1\n" + rebuiltGood(iccidX, "refA") + "\n#rebuilt\n#mine|" + iccidY + "|\n")
	if st.flawed || !st.rebuilt || len(st.lines) != 1 || len(st.damaged) != 0 {
		t.Fatalf("flawed=%v rebuilt=%v lines=%d damaged=%v, want a rebuilt file that is not flawed", st.flawed, st.rebuilt, len(st.lines), st.damaged)
	}
	if !st.mineTag(simTag(iccidY)) || st.mineTag(simTag(iccidZ)) || len(st.mine) != 1 {
		t.Fatalf("mine=%v, want only Y", st.mine)
	}
	for _, bad := range []string{"#mine||", "#mine|", "#mine|" + iccidY, "#mine|" + iccidY + "|x", "#rebuilt ", "#mine|a|b|"} {
		got := parseBindingsText("v1\n" + bad + "\n")
		if !got.flawed || len(got.damaged) != 1 || got.rebuilt || len(got.mine) != 0 {
			t.Errorf("%q: flawed=%v damaged=%v rebuilt=%v mine=%v, want one damaged line", bad, got.flawed, got.damaged, got.rebuilt, got.mine)
		}
	}
	for _, row := range []string{"#rebuilt", "#mine|" + iccidY + "|"} {
		if _, ok := parseLineStrict(row); ok {
			t.Errorf("parseLineStrict accepted %q", row)
		}
	}
	two := parseBindingsText("v1\n#rebuilt\n#rebuilt\n#mine|" + iccidY + "|\n#mine|" + iccidY + "|\n")
	if two.flawed || len(two.mine) != 1 {
		t.Errorf("a repeated record: flawed=%v mine=%v, want it dropped without damage", two.flawed, two.mine)
	}
}

func TestBindingsRebuiltRoundTrip(t *testing.T) {
	useTempBindings(t)
	x := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refA", "pubrefA"}}}
	if err := writeBindingsMarked([]simBinding{x}, []string{"7|" + iccidZ + "|"}, bindingsMarks{rebuilt: true, mine: []string{iccidY}}); err != nil {
		t.Fatal(err)
	}
	want := "v1\n" + rebuiltGood(iccidX, "refA") + "\n#rebuilt\n#mine|" + iccidY + "|\n#7|" + iccidZ + "|\n"
	if got := rebuiltRead(t); got != want {
		t.Fatalf("file %q, want %q", got, want)
	}
	st := readBindingsState()
	if !st.rebuilt || len(st.mine) != 1 || st.mine[0] != iccidY || len(st.damaged) != 1 || !st.flawed {
		t.Fatalf("read back rebuilt=%v mine=%v damaged=%v flawed=%v", st.rebuilt, st.mine, st.damaged, st.flawed)
	}
	if err := writeBindingsMarked([]simBinding{x}, nil, bindingsMarks{rebuilt: true, mine: []string{iccidY}}); err != nil {
		t.Fatal(err)
	}
	if st := readBindingsState(); st.flawed || !st.rebuilt || !st.mineTag(simTag(iccidY)) {
		t.Fatalf("second write: flawed=%v rebuilt=%v mine=%v", st.flawed, st.rebuilt, st.mine)
	}
	useTempBindings(t)
	if err := writeBindingsMarked(nil, nil, bindingsMarks{mine: []string{"a|b"}}); !errors.Is(err, errBindingUnstorable) {
		t.Fatalf("an unstorable mine ICCID gave %v, want errBindingUnstorable", err)
	}
	if _, err := os.Stat(bindingsPath); err == nil {
		t.Fatal("a refused write created the file")
	}
}

func TestBindingsRebuiltArrivalLine(t *testing.T) {
	useTempBindings(t)
	useArrivalState(t)
	rebuiltPut(t, "v1\n"+rebuiltGood(iccidX, "refA")+"\n#rebuilt\n#mine|"+iccidY+"|\n")
	if c := rebuiltClass(t, iccidZ); c != lineDamaged {
		t.Errorf("an unnamed SIM in a rebuilt file is class %v, want lineDamaged", c)
	}
	if c := rebuiltClass(t, iccidY); c != lineUnbound {
		t.Errorf("a mine SIM is class %v, want lineUnbound", c)
	}
	if c := rebuiltClass(t, iccidX); c != lineBound {
		t.Errorf("a bound SIM is class %v, want lineBound", c)
	}
}

func TestBindingsRebuiltCleanControl(t *testing.T) {
	useTempBindings(t)
	useArrivalState(t)
	rebuiltPut(t, "v1\n"+rebuiltGood(iccidX, "refA")+"\n")
	if c := rebuiltClass(t, iccidZ); c != lineUnbound {
		t.Errorf("an unnamed SIM in an unmarked clean file is class %v, want lineUnbound", c)
	}
}

func TestBindingsRebuiltOnRewrite(t *testing.T) {
	cases := []struct {
		name  string
		start string
		write func() error
	}{
		{"empty file", "", func() error { return setBindingOwner(1, iccidX, "L", "open", "refA", "pubA") }},
		{"no header", rebuiltGood(iccidX, "refA") + "\n", func() error { return setBindingOwner(1, iccidY, "L", "open", "refB", "pubB") }},
		{"cut-short header", "v1", func() error { return setBindingOwner(1, iccidX, "L", "open", "refA", "pubA") }},
		{"a line naming no ICCID dropped by a delete", "v1\n" + rebuiltGood(iccidX, "refA") + "\nzz\n", func() error {
			n, err := removeBindingOwnerEverywhere("refGone")
			if err == nil && n == 0 {
				return errors.New("the delete dropped nothing")
			}
			return err
		}},
		{"Unbind all of a damaged line's ICCID", "v1\n" + rebuiltGood(iccidX, "refA") + "\n2|" + iccidY + "|L!|open|refB:pubB\n", func() error {
			_, err := removeBindingOwner(iccidY, "")
			return err
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			useTempBindings(t)
			useArrivalState(t)
			rebuiltPut(t, c.start)
			if err := c.write(); err != nil {
				t.Fatal(err)
			}
			if got := rebuiltRead(t); !strings.Contains(got, "\n#rebuilt\n") {
				t.Fatalf("the written file %q carries no #rebuilt mark", got)
			}
			if st := readBindingsState(); st.flawed || !st.rebuilt {
				t.Fatalf("flawed=%v rebuilt=%v, want a rebuilt file that is not flawed", st.flawed, st.rebuilt)
			}
			if cl := rebuiltClass(t, iccidZ); cl != lineDamaged {
				t.Errorf("an unnamed SIM is class %v after the rewrite, want lineDamaged", cl)
			}
		})
	}
	t.Run("repaired SIM stays unresolved", func(t *testing.T) {
		useTempBindings(t)
		useArrivalState(t)
		rebuiltPut(t, "v1\n"+rebuiltGood(iccidX, "refA")+"\n2|"+iccidY+"|L!|open|refB:pubB\n")
		if _, err := removeBindingOwner(iccidY, ""); err != nil {
			t.Fatal(err)
		}
		if cl := rebuiltClass(t, iccidY); cl != lineDamaged {
			t.Errorf("the repaired SIM is class %v, want lineDamaged", cl)
		}
	})
}

func TestBindingsRebuiltMarksSurviveEveryWriter(t *testing.T) {
	base := "v1\n" + rebuiltGood(iccidX, "refA") + "\n" + rebuiltGood(iccidZ, "refB") + "\n#rebuilt\n#mine|" + iccidY + "|\n"
	writers := map[string]func() error{
		"setBindingOwner": func() error { return setBindingOwner(1, iccidZ, "L", "open", "refC", "pubC") },
		"removeBindingOwner": func() error {
			n, err := removeBindingOwner(iccidX, "refA")
			if err == nil && n != 1 {
				err = errors.New("nothing removed")
			}
			return err
		},
		"removeBindingOwnerEverywhere": func() error {
			n, err := removeBindingOwnerEverywhere("refA")
			if err == nil && n != 1 {
				err = errors.New("nothing removed")
			}
			return err
		},
		"renameBindingOwnerEverywhereLocked": func() error {
			telMu.Lock()
			defer telMu.Unlock()
			n, err := renameBindingOwnerEverywhereLocked("refA", "refN")
			if err == nil && n != 1 {
				err = errors.New("nothing renamed")
			}
			return err
		},
	}
	for name, w := range writers {
		t.Run(name, func(t *testing.T) {
			useTempBindings(t)
			useArrivalState(t)
			rebuiltPut(t, base)
			if err := w(); err != nil {
				t.Fatal(err)
			}
			got := rebuiltRead(t)
			if !strings.Contains(got, "\n#rebuilt\n#mine|"+iccidY+"|\n") {
				t.Fatalf("the written file %q lost the rebuilt mark or the mine record", got)
			}
			if st := readBindingsState(); !st.rebuilt || !st.mineTag(simTag(iccidY)) || st.flawed {
				t.Fatalf("rebuilt=%v mine=%v flawed=%v", st.rebuilt, st.mine, st.flawed)
			}
		})
	}
}

func TestBindingsRebuiltAbsentFileStaysUnmarked(t *testing.T) {
	useTempBindings(t)
	if err := setBindingOwner(1, iccidX, "L", "open", "refA", "pubA"); err != nil {
		t.Fatal(err)
	}
	if got := rebuiltRead(t); strings.Contains(got, "#rebuilt") {
		t.Fatalf("a first bind wrote %q, want an unmarked file", got)
	}
	if st := readBindingsState(); st.rebuilt {
		t.Fatal("a first bind wrote a rebuilt file")
	}
}

func TestBindingsRebuiltSimUnboundNow(t *testing.T) {
	useTempBindings(t)
	rebuiltPut(t, "v1\n"+rebuiltGood(iccidX, "refA")+"\n#rebuilt\n#mine|"+iccidY+"|\n")
	if simUnboundNow(simTag(iccidZ)) {
		t.Error("an unnamed SIM in a rebuilt file reads as unbound")
	}
	if !simUnboundNow(simTag(iccidY)) {
		t.Error("a mine SIM in a rebuilt file does not read as unbound")
	}
	rebuiltPut(t, "v1\n"+rebuiltGood(iccidX, "refA")+"\n")
	if !simUnboundNow(simTag(iccidZ)) {
		t.Error("an unnamed SIM in a clean file does not read as unbound")
	}
}

func TestBindingsRebuiltCutShortMarkIsDamaged(t *testing.T) {
	st := parseBindingsText("v1\n" + rebuiltGood(iccidX, "refA") + "\n#rebuilt")
	if !st.flawed || st.rebuilt || len(st.damaged) != 1 || st.damaged[0] != "#rebuilt" {
		t.Fatalf("flawed=%v rebuilt=%v damaged=%v, want a damaged cut-short #rebuilt", st.flawed, st.rebuilt, st.damaged)
	}
}
