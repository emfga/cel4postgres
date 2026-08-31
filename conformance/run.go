package conformance

import (
	"context"
	"encoding/json"
	"fmt"

	test "cel.dev/expr/conformance/test"
	"github.com/jackc/pgx/v5"

	"github.com/emfga/cel4postgres/internal/codec"
)

// Running a conformance case lives here rather than in the test file
// because two callers need it: the suite, and the report generator
// (internal/cmd/confreport). A report that ran the corpus its own way
// could claim a pass the suite fails, so there is one execution path
// and the suite is a thin wrapper over it.

// Status is the outcome of one conformance case.
type Status int

const (
	// Passed means the case ran and matched the corpus expectation.
	Passed Status = iota
	// Skipped means the case was not attempted; Detail says why.
	Skipped
	// Failed means the case ran and disagreed with the corpus, or
	// could not be run at all; Detail says which.
	Failed
)

// CaseResult is what running one corpus case produced.
type CaseResult struct {
	File    string
	Section string
	Name    string
	Status  Status
	// Detail is the skip reason for Skipped and the failure message
	// for Failed, and is empty for Passed.
	Detail string
}

// StageSet records which cel.* entry points exist in the database, so
// failures name the missing stage rather than surfacing SQL errors.
type StageSet struct {
	Parse, Check, Eval bool
}

// InstalledStages probes the database once per run, so a
// not-yet-implemented stage fails each case with one clear line
// instead of thousands of undefined-function SQL errors, and so a
// missing function can never masquerade as a CEL error an eval_error
// case would spuriously pass on.
func InstalledStages(
	ctx context.Context, conn *pgx.Conn,
) (StageSet, error) {
	var stages StageSet
	err := conn.QueryRow(ctx,
		`SELECT to_regprocedure('cel.parse(text, text)') IS NOT NULL,
		        to_regprocedure('cel.check(jsonb, text, jsonb)')
		            IS NOT NULL,
		        to_regprocedure('cel.eval(jsonb, jsonb, text)')
		            IS NOT NULL`,
	).Scan(&stages.Parse, &stages.Check, &stages.Eval)
	if err != nil {
		return stages, fmt.Errorf("probe installed stages: %w", err)
	}
	return stages, nil
}

// RunCase parses, checks and evaluates one corpus case against the
// database and compares the outcome to the case's result matcher.
func RunCase(
	ctx context.Context,
	conn *pgx.Conn,
	stages StageSet,
	file, section string,
	tc *test.SimpleTest,
) CaseResult {
	result := CaseResult{File: file, Section: section, Name: tc.GetName()}

	if reason := skipReason(file, section, tc.GetName()); reason != "" {
		result.Status = Skipped
		result.Detail = reason
		return result
	}

	status, detail := runCase(ctx, conn, stages, file, tc)
	result.Status = status
	result.Detail = detail
	return result
}

// runCase returns Passed with an empty detail, or Failed with the
// message the suite reports.
func runCase(
	ctx context.Context,
	conn *pgx.Conn,
	stages StageSet,
	file string,
	tc *test.SimpleTest,
) (Status, string) {
	fail := func(format string, args ...any) (Status, string) {
		return Failed, fmt.Sprintf(format, args...)
	}

	env := EnvFor(file)

	// Parse.
	if !stages.Parse {
		return fail("parse stage: cel.parse(text, text) is not installed")
	}
	var raw []byte
	err := conn.QueryRow(ctx,
		"SELECT cel.parse($1, $2)", tc.GetExpr(), env,
	).Scan(&raw)
	if err != nil {
		return fail("parse stage: %v", err)
	}
	ast, err := codec.Decode(raw)
	if err != nil {
		return fail("parse stage: %v", err)
	}
	if errs, failed := stageErrors(ast); failed {
		if expectsError(tc) {
			return Passed, ""
		}
		return fail("parse stage: expression rejected: %v", errs)
	}

	// Check.
	if !tc.GetDisableCheck() {
		if !stages.Check {
			return fail(
				"check stage: cel.check(jsonb, text, jsonb) " +
					"is not installed",
			)
		}
		options, err := checkOptions(tc)
		if err != nil {
			return fail("check stage: %v", err)
		}
		err = conn.QueryRow(ctx,
			"SELECT cel.check($1, $2, $3)", raw, env, options,
		).Scan(&raw)
		if err != nil {
			return fail("check stage: %v", err)
		}
		ast, err = codec.Decode(raw)
		if err != nil {
			return fail("check stage: %v", err)
		}
		if errs, failed := stageErrors(ast); failed {
			if expectsError(tc) {
				return Passed, ""
			}
			return fail("check stage: expression rejected: %v", errs)
		}
	}

	if tc.GetCheckOnly() {
		if err := compareDeducedType(ast, tc); err != nil {
			return fail("%v", err)
		}
		return Passed, ""
	}

	// Eval.
	if !stages.Eval {
		return fail(
			"eval stage: cel.eval(jsonb, jsonb, text) is not installed",
		)
	}
	activation, err := activationJSON(tc)
	if err != nil {
		return fail("eval stage: %v", err)
	}
	// The container reaches eval too: unchecked evaluation resolves
	// names at runtime (checked ASTs bind them at check time, where
	// the same option arrives via checkOptions).
	evalOptions := map[string]any{}
	if tc.GetContainer() != "" {
		evalOptions["container"] = tc.GetContainer()
	}
	evalOptionsJSON, err := json.Marshal(evalOptions)
	if err != nil {
		return fail("eval stage: %v", err)
	}
	var rawResult []byte
	err = conn.QueryRow(ctx,
		"SELECT cel.eval($1, $2, $3, $4)",
		raw, activation, env, evalOptionsJSON,
	).Scan(&rawResult)
	if err != nil {
		return fail("eval stage: %v", err)
	}
	got, err := codec.Decode(rawResult)
	if err != nil {
		return fail("eval stage: %v", err)
	}

	if err := compareResult(got, rawResult, tc); err != nil {
		return fail("%v", err)
	}

	// typed_result compares the deduced type in addition to the value.
	if _, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult); ok {
		if err := compareDeducedType(ast, tc); err != nil {
			return fail("%v", err)
		}
	}

	return Passed, ""
}

// expectsError reports whether the case's result matcher is
// eval_error. Parse and check failures pass exactly these cases; the
// corpus never asserts on error message text (measured -- plumbing
// carries a deliberately bogus one), so existence is the whole test.
func expectsError(tc *test.SimpleTest) bool {
	_, ok := tc.GetResultMatcher().(*test.SimpleTest_EvalError)
	return ok
}

// stageErrors extracts the {"errors": [...]} failure shape that
// cel.parse and cel.check return instead of an envelope.
func stageErrors(envelope any) ([]any, bool) {
	m, ok := envelope.(map[string]any)
	if !ok {
		return nil, false
	}
	errs, ok := m["errors"].([]any)
	return errs, ok
}

// checkOptions builds the options argument of cel.check: the case's
// container and its type_env ident declarations.
func checkOptions(tc *test.SimpleTest) ([]byte, error) {
	options := map[string]any{}
	if tc.GetContainer() != "" {
		options["container"] = tc.GetContainer()
	}
	if typeEnv := tc.GetTypeEnv(); len(typeEnv) > 0 {
		decls := []any{}
		for _, decl := range typeEnv {
			converted, err := codec.FromDecl(decl)
			if err != nil {
				return nil, err
			}
			decls = append(decls, converted)
		}
		options["decls"] = decls
	}
	return json.Marshal(options)
}

// activationJSON builds cel.eval's activation: binding name to tagged
// value, always tagged -- the runner never sends plain JSON the
// evaluator would have to guess about.
func activationJSON(tc *test.SimpleTest) ([]byte, error) {
	activation := map[string]any{}
	for name, value := range tc.GetBindings() {
		tagged, err := codec.FromExprValue(value)
		if err != nil {
			return nil, fmt.Errorf("binding %q: %w", name, err)
		}
		activation[name] = tagged
	}
	return json.Marshal(activation)
}

// compareResult applies the case's result matcher. A missing matcher
// defaults to value: bool true (measured against cel-go v0.32.0).
func compareResult(got any, rawResult []byte, tc *test.SimpleTest) error {
	compare := func(want any) error {
		if codec.Equal(want, got) {
			return nil
		}
		wantJSON, _ := json.Marshal(want)
		return fmt.Errorf("result mismatch:\n  want %s\n  got  %s",
			wantJSON, rawResult)
	}

	switch matcher := tc.GetResultMatcher().(type) {
	case *test.SimpleTest_Value:
		want, err := codec.FromValue(matcher.Value)
		if err != nil {
			return fmt.Errorf("convert expected value: %w", err)
		}
		return compare(want)
	case *test.SimpleTest_EvalError:
		if kind, _ := taggedKind(got); kind != "error" {
			return fmt.Errorf("expected an error value, got %s",
				rawResult)
		}
		return nil
	case *test.SimpleTest_TypedResult:
		want, err := codec.FromValue(matcher.TypedResult.GetResult())
		if err != nil {
			return fmt.Errorf("convert expected value: %w", err)
		}
		return compare(want)
	case nil:
		return compare(map[string]any{"@t": "bool", "v": true})
	default:
		// unknown / any_unknowns / any_eval_errors: zero corpus
		// cases use them today (measured); a corpus update that
		// introduces one must extend the runner, not pass silently.
		return fmt.Errorf("unsupported result matcher %T", matcher)
	}
}

// compareDeducedType compares the checked AST's root type against the
// typed_result matcher's deduced type (check_only cases,
// type_deduction file).
func compareDeducedType(ast any, tc *test.SimpleTest) error {
	typed, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult)
	if !ok {
		return fmt.Errorf("check_only case without typed_result matcher")
	}

	want, err := codec.FromType(typed.TypedResult.GetDeducedType())
	if err != nil {
		return fmt.Errorf("convert expected type: %w", err)
	}

	envelope, ok := ast.(map[string]any)
	if !ok {
		return fmt.Errorf("checked AST is not an object")
	}
	root, ok := envelope["expr"].(map[string]any)
	if !ok {
		return fmt.Errorf("checked AST has no root expression")
	}
	rootID, ok := root["id"].(json.Number)
	if !ok {
		return fmt.Errorf("root expression has no id")
	}
	types, ok := envelope["types"].(map[string]any)
	if !ok {
		return fmt.Errorf("AST is not checked: no types map")
	}

	return compareTypeJSON(want, types[rootID.String()])
}

// compareTypeJSON compares a deduced type against the expected one in
// the rendered shape both sides share, so the AST's types map and a
// type converted from cel-go are judged identically.
func compareTypeJSON(want codec.TypeJSON, got any) error {
	wantJSON, _ := json.Marshal(want)
	gotJSON, _ := json.Marshal(got)
	if string(wantJSON) != string(gotJSON) {
		return fmt.Errorf("deduced type mismatch:\n  want %s\n  got  %s",
			wantJSON, gotJSON)
	}
	return nil
}

func taggedKind(v any) (string, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", false
	}
	kind, ok := m["@t"].(string)
	return kind, ok
}
