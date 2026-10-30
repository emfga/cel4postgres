package conformance

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"testing"

	expr "cel.dev/expr"
	test "cel.dev/expr/conformance/test"

	"github.com/emfga/cel4postgres/internal/oracle"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// The corpus calls a fraction of each extension library, and nothing
// in it calls what cel-go added after the pinned cel-spec release.
// These tests close that gap two ways: overload by overload against
// the oracle's declarations, and case by case for the functions the
// corpus never reaches.

// knownMissing names every overload the oracle declares and the
// registry deliberately does not, with the reason. The list is
// printed on every run; an entry that gets implemented has to be
// removed, and an overload cel-go adds has to be implemented or
// named here, or TestLibraryOverloads fails.
var knownMissing = map[string]map[string]string{
	"standard": {
		"__not_strictly_false__": "deprecated alias of " +
			"not_strictly_false; no parser emits it",
	},
	"bindings": {
		"cel_block_list": "cel.@block is cel-go-internal " +
			"(block_ext is skipped)",
	},
	"encoders": {
		"json_encode_dyn":        jsonYAMLReason,
		"json_parse_string":      jsonYAMLReason,
		"json_parse_string_type": jsonYAMLReason,
		"yaml_encode_dyn":        jsonYAMLReason,
		"yaml_parse_string":      jsonYAMLReason,
		"yaml_parse_string_type": jsonYAMLReason,
	},
}

const jsonYAMLReason = "json/yaml encoders not implemented " +
	"(docs/CONFORMANCE.md)"

func TestLibraryOverloads(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	standard, err := oracle.OverloadIDs("standard")
	if err != nil {
		t.Fatal(err)
	}

	for _, name := range oracle.EnvNames() {
		t.Run(name, func(t *testing.T) {
			env := "standard," + name
			if name == "standard" {
				env = name
			}
			reference, err := oracle.OverloadIDs(env)
			if err != nil {
				t.Fatal(err)
			}

			rows, err := conn.Query(ctx,
				"SELECT ref FROM cel.env_item"+
					" WHERE env = $1 AND kind = 'overload'",
				name)
			if err != nil {
				t.Fatal(err)
			}
			ours := map[string]bool{}
			for rows.Next() {
				var id string
				if err := rows.Scan(&id); err != nil {
					t.Fatal(err)
				}
				ours[id] = true
			}
			if err := rows.Err(); err != nil {
				t.Fatal(err)
			}

			known := knownMissing[name]
			var missing, extra, stale []string
			for id := range reference {
				// An extension env is compared on what it adds.
				if name != "standard" && standard[id] {
					continue
				}
				if ours[id] {
					if _, listed := known[id]; listed {
						stale = append(stale, id)
					}
					continue
				}
				if _, listed := known[id]; !listed {
					missing = append(missing, id)
				}
			}
			for id := range ours {
				if !reference[id] {
					extra = append(extra, id)
				}
			}
			for id := range known {
				if !reference[id] {
					stale = append(stale, id)
				}
			}

			for _, id := range sortedKeys(known) {
				t.Logf("not implemented: %s %s -- %s",
					name, id, known[id])
			}
			report := func(what string, ids []string) {
				if len(ids) > 0 {
					sort.Strings(ids)
					t.Errorf("%s: %s", what, strings.Join(ids, ", "))
				}
			}
			report("cel-go declares, registry lacks "+
				"(implement or add to knownMissing)", missing)
			report("registry has, cel-go does not declare", extra)
			report("knownMissing entries to remove", stale)
		})
	}
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// libraryCase is one expression run through cel-go and cel4postgres
// under the same env; cel-go's outcome becomes the expectation.
// want says which outcome cel-go must produce, so a case can never
// pass because both sides rejected an undeclared function.
type libraryCase struct {
	expr string
	want outcome
}

type outcome int

const (
	value      outcome = iota // evaluates to a value
	evalError                 // checks, then errors at evaluation
	checkError                // rejected by the type checker
)

// libraryCases are keyed by corpus file name, which selects the env
// exactly as it does for that file (EnvFor).
var libraryCases = map[string][]libraryCase{
	"lists_ext": {
		{"[].hasOnly([1, 2])", value},
		{"[1, 1, 2].hasOnly([1, 2, 3])", value},
		{"[1, 2.0, 3u].hasOnly([1.0, 2u, 3])", value},
		{"[1, 4].hasOnly([1, 2, 3])", value},
		{"[1].hasOnly([])", value},
		{"[1, 2, 3].hasAny([3, 4])", value},
		{"[[1], [2, 3]].hasAny([[1, 2], [2, 3.0]])", value},
		{"[1, 2].hasAny([3, 4])", value},
		{"[1].hasAny([])", value},
		{"[].hasAny([])", value},
		{"[1, 2, 3].hasAll([])", value},
		{"[1, 2, 3, 4].hasAll([2, 3])", value},
		{"[1, 2.0, 3u].hasAll([1.0, 2u, 3])", value},
		{"[1, 2, 3].hasAll([2, 4])", value},
		{"[].hasExactly([])", value},
		{"[1].hasExactly([1, 1])", value},
		{"[1].hasExactly([1u, 1.0])", value},
		{"[1, 2, 3].hasExactly([3u, 2.0, 1])", value},
		{"[1, 2].hasExactly([1, 2, 3])", value},
		{"[{'a': 1}].hasAll([{'a': 1.0}])", checkError},
		{"[{'a': 1}].hasAll([dyn({'a': 1.0})])", value},
		{"['a', 'b'].hasOnly(['b', 'a', 'c'])", value},
		{"[1].hasAll(['a'])", checkError},
		{"[1].hasAny(1)", checkError},
		{"[1, 2][5] == 1 || [1].hasAll([1])", value},
		{"[1].hasAll([[1, 2][5]])", evalError},
	},
	"encoders_ext": {
		{"base64.encodeUrl(b'hello')", value},
		{"base64.encodeUrl(b'\\xff\\xff\\xff')", value},
		{"base64.encodeUrl(b'\\xfb\\xff')", value},
		{"base64.encodeUrl(b'')", value},
		{"base64.decodeUrl('aGVsbG8=')", value},
		{"base64.decodeUrl('aGVsbG8')", value},
		{"base64.decodeUrl('____')", value},
		{"base64.decodeUrl('-_8')", value},
		{"base64.decodeUrl('')", value},
		{"base64.decodeUrl('////')", evalError},
		{"base64.decodeUrl('++++')", evalError},
		{"base64.decodeUrl('a')", evalError},
		{"base64.decodeUrl('!!!!')", evalError},
		{"base64.decodeUrl(base64.encodeUrl(b'\\x00\\xfe\\xff')) " +
			"== b'\\x00\\xfe\\xff'", value},
		{"base64.encodeUrl('abc')", checkError},
	},
	"optionals": {
		{"optional.of(42).hasValue(42)", value},
		{"optional.of(42).hasValue(21)", value},
		{"optional.none().hasValue(42)", value},
		{"optional.of(42).hasValue(42.0)", checkError},
		{"optional.of(dyn(42)).hasValue(42.0)", value},
		{"optional.of(optional.of(42)).hasValue(optional.of(42))",
			value},
		{"optional.of(42).hasValue(dyn(optional.of(42)))", value},
		{"optional.of(42).hasValue(dyn(42))", value},
		{"optional.of([1, 2]).hasValue([1, 2])", value},
		{"{'a': 1}[?'a'].hasValue(1)", value},
		{"{'a': 1}[?'b'].hasValue(1)", value},
		{"[1, 2, 3].first().value()", value},
		{"[1, 2, 3].last().value()", value},
		{"[].first().hasValue()", value},
		{"[].last().hasValue()", value},
		{"[[1]].last().value()", value},
		{"optional.unwrap([optional.of(42), optional.none()])", value},
		{"[optional.of(42), optional.none()].unwrapOpt()", value},
		{"optional.unwrap([])", value},
		{"[optional.none(), optional.none()].unwrapOpt()", value},
		{"optional.unwrap([1])", checkError},
		{"optional.unwrap(dyn([1]))", evalError},
		{"optional.of(1 + 1).optMap(x, x * 2).value()", value},
		{"optional.none().optMap(x, x * 2).hasValue()", value},
		{"[1, 2][?0].optFlatMap(x, [x][?0]).value()", value},
		{"{'k': {}}.?k.optFlatMap(k, k.?sub).hasValue()", value},
	},
}

func TestLibraryCases(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	stages, err := InstalledStages(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}

	for _, file := range []string{
		"encoders_ext", "lists_ext", "optionals",
	} {
		for i, lc := range libraryCases[file] {
			name := fmt.Sprintf("%s/%02d", file, i)
			t.Run(name, func(t *testing.T) {
				tc := &test.SimpleTest{Name: name, Expr: lc.expr}

				ref, err := oracle.RunCase(tc, EnvFor(file))
				if err != nil {
					t.Fatal(err)
				}

				switch {
				case lc.want == value && ref.Err == nil:
					tc.ResultMatcher = &test.SimpleTest_Value{
						Value: ref.Value,
					}
				case lc.want == evalError && ref.Err != nil &&
					ref.Type != nil:
					tc.ResultMatcher = &test.SimpleTest_EvalError{
						EvalError: &expr.ErrorSet{},
					}
				case lc.want == checkError && ref.Err != nil &&
					ref.Type == nil:
					tc.ResultMatcher = &test.SimpleTest_EvalError{
						EvalError: &expr.ErrorSet{},
					}
					tc.CheckOnly = true
				default:
					t.Fatalf("%s: cel-go outcome does not match the "+
						"case (value %v, type %v, err %v)",
						lc.expr, ref.Value, ref.Type, ref.Err)
				}

				result := RunCase(ctx, conn, stages, file, "library", tc)
				if result.Status != Passed {
					t.Fatalf("%s: %s", lc.expr, result.Detail)
				}
			})
		}
	}
}
