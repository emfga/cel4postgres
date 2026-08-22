package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"

	"github.com/emfga/cel4postgres/internal/codec"
	"github.com/emfga/cel4postgres/internal/oracle"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// TestUnknownPropagation is the coverage for day-one invariant 4 that
// the conformance corpus cannot provide: unknowns.textproto is an
// empty stub, so unknown propagation is measured directly against
// cel-go partial evaluation (oracle.EvalPartial). Each case runs both
// evaluators; outcomes must agree in class (unknown / error / value),
// and concrete scalar values must agree exactly.
//
// Our side represents an unknown input as the tagged unknown value
// {"@t": "unknown", "v": [<id>]}; cel-go derives unknowns from
// declared-but-unbound variables under a partial activation. Unknown
// ids are not comparable across the two (cel-go tracks attribute
// trails, we track expression ids), so agreement is asserted on the
// outcome class, which is what the semantics prescribe.
func TestUnknownPropagation(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	cases := []struct {
		name  string
		expr  string
		known map[string]any
		vars  []string // every declared variable, known or not
	}{
		// Commutative absorption across && and ||.
		{"and_absorbs_unknown_left", "x && false", nil, []string{"x"}},
		{"and_absorbs_unknown_right", "false && x", nil, []string{"x"}},
		{"and_keeps_unknown", "x && true", nil, []string{"x"}},
		{"or_absorbs_unknown_left", "x || true", nil, []string{"x"}},
		{"or_absorbs_unknown_right", "true || x", nil, []string{"x"}},
		{"or_keeps_unknown", "x || false", nil, []string{"x"}},
		// Error and unknown interaction: unknown wins over error in
		// logic operators.
		{"and_error_and_unknown", "(1 / 0 == 1) && x", nil,
			[]string{"x"}},
		{"or_error_and_unknown", "(1 / 0 == 1) || x", nil,
			[]string{"x"}},
		// Conditionals: only the taken branch matters.
		{"cond_unknown_condition", "x ? 1 : 2", nil, []string{"x"}},
		{"cond_unknown_taken", "true ? x : 2", nil, []string{"x"}},
		{"cond_unknown_not_taken", "true ? 1 : x", nil, []string{"x"}},
		// Strict functions and operators propagate.
		{"add_propagates", "x + 1", nil, []string{"x"}},
		{"eq_propagates", "x == 1", nil, []string{"x"}},
		{"conversion_propagates", "string(x)", nil, []string{"x"}},
		// Containers carry unknowns per element.
		{"list_index_hits_unknown", "[x, 1][0]", nil, []string{"x"}},
		{"list_index_misses_unknown", "[x, 1][1]", nil, []string{"x"}},
		{"map_value_unknown", "{'a': x}['a']", nil, []string{"x"}},
		// Merging: two distinct unknowns meet.
		{"merge_two_unknowns", "x == y", nil, []string{"x", "y"}},
		// Mixed known/unknown activation.
		{"known_beside_unknown", "x + y",
			map[string]any{"y": int64(2)}, []string{"x", "y"}},
		// Comprehensions: absorption inside the fold.
		{"exists_absorbs_unknown", "[1, x].exists(i, i == 1)", nil,
			[]string{"x"}},
		{"exists_keeps_unknown", "[1, x].exists(i, i == 2)", nil,
			[]string{"x"}},
		{"all_keeps_unknown", "[1, x].all(i, i == 1)", nil,
			[]string{"x"}},
		{"all_absorbs_unknown", "[2, x].all(i, i == 1)", nil,
			[]string{"x"}},
		{"range_unknown", "x.all(i, i > 0)", nil, []string{"x"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			options := make([]cel.EnvOption, 0, len(tc.vars))
			for _, v := range tc.vars {
				options = append(options, cel.Variable(v, cel.DynType))
			}
			refVal, refErr := oracle.EvalPartial(
				tc.expr, tc.known, options...)

			activation := map[string]any{}
			unknownID := 9001
			for _, v := range tc.vars {
				if known, ok := tc.known[v]; ok {
					activation[v] = tagScalar(t, known)
					continue
				}
				activation[v] = map[string]any{
					"@t": "unknown", "v": []any{unknownID},
				}
				unknownID++
			}
			activationJSON, err := json.Marshal(activation)
			if err != nil {
				t.Fatal(err)
			}

			var raw []byte
			err = conn.QueryRow(ctx,
				"SELECT cel.eval(cel.parse($1, 'standard'), $2,"+
					" 'standard')",
				tc.expr, activationJSON,
			).Scan(&raw)
			if err != nil {
				t.Fatalf("eval: %v", err)
			}
			got, err := codec.Decode(raw)
			if err != nil {
				t.Fatal(err)
			}
			kind, _ := taggedKind(got)

			switch {
			case refErr != nil:
				if kind != "error" {
					t.Fatalf(
						"cel-go errored (%v), got %s", refErr, raw)
				}
			case types.IsUnknown(refVal):
				if kind != "unknown" {
					t.Fatalf("cel-go returned unknown, got %s", raw)
				}
			default:
				want, err := tagRefScalar(refVal)
				if err != nil {
					t.Fatalf("reference result: %v", err)
				}
				if !codec.Equal(want, got) {
					t.Fatalf("cel-go returned %v, got %s", refVal, raw)
				}
			}
		})
	}
}

// tagScalar converts a Go scalar used in a known activation binding to
// the tagged-value encoding.
func tagScalar(t *testing.T, v any) map[string]any {
	t.Helper()
	switch x := v.(type) {
	case bool:
		return map[string]any{"@t": "bool", "v": x}
	case int64:
		return map[string]any{"@t": "int", "v": x}
	case string:
		return map[string]any{"@t": "string", "v": x}
	}
	t.Fatalf("unsupported known binding %T", v)
	return nil
}

// tagRefScalar converts a concrete cel-go scalar result to the tagged
// encoding for comparison. The suite's cases are designed so every
// concrete outcome is a scalar.
func tagRefScalar(v any) (map[string]any, error) {
	switch x := v.(type) {
	case types.Bool:
		return map[string]any{"@t": "bool", "v": bool(x)}, nil
	case types.Int:
		return map[string]any{
			"@t": "int", "v": json.Number(fmt.Sprint(int64(x))),
		}, nil
	case types.String:
		return map[string]any{"@t": "string", "v": string(x)}, nil
	}
	return nil, fmt.Errorf("non-scalar reference result %T", v)
}
