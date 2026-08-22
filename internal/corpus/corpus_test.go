package corpus

import "testing"

// The corpus is external input: these tests pin the facts the suite
// depends on -- the checkout is findable, every file parses, and the
// file census matches what the conformance target (workspace doc 01)
// was measured against. A count change here means the corpus moved
// and the target needs re-measuring, not that this test is wrong.

func TestEveryFileParses(t *testing.T) {
	files, err := Files()
	if err != nil {
		t.Fatal(err)
	}

	// 25 included + 6 excluded. Workspace doc 01 said "26 of 32";
	// the corpus at the pinned checkout has 31 -- recorded in the
	// workspace ISSUES register when this was measured.
	if len(files) != 31 {
		t.Errorf("corpus has %d files, the target was measured on 31",
			len(files))
	}

	for _, name := range files {
		file, err := Load(name)
		if err != nil {
			t.Errorf("load %s: %v", name, err)
			continue
		}
		// The declared name usually matches the filename, but not
		// always: type_deduction.textproto declares
		// "type_deductions". The suite keys by filename.
		if file.GetName() == "" {
			t.Errorf("%s.textproto declares no name", name)
		}
	}
}

func TestKnownCasePresent(t *testing.T) {
	file, err := Load("basic")
	if err != nil {
		t.Fatal(err)
	}

	for _, section := range file.GetSection() {
		if section.GetName() != "self_eval_zeroish" {
			continue
		}
		for _, tc := range section.GetTest() {
			if tc.GetName() == "self_eval_int_zero" {
				if tc.GetExpr() != "0" {
					t.Fatalf("self_eval_int_zero expr = %q", tc.GetExpr())
				}
				return
			}
		}
	}
	t.Fatal("basic/self_eval_zeroish/self_eval_int_zero not found")
}
