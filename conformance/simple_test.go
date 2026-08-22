package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"testing"

	test "cel.dev/expr/conformance/test"
	"github.com/jackc/pgx/v5"

	"github.com/emfga/cel4postgres/internal/codec"
	"github.com/emfga/cel4postgres/internal/corpus"
	"github.com/emfga/cel4postgres/internal/testdb"
)

// TestMain prints the skip report before the run: every file-level
// skip with its reason, and the count of case-level skips. Coverage
// must never shrink silently, so what is not attempted is announced
// on every run, not discoverable only with -v.
func TestMain(m *testing.M) {
	files := make([]string, 0, len(SkippedFiles))
	for file := range SkippedFiles {
		files = append(files, file)
	}
	sort.Strings(files)

	fmt.Printf("conformance: skipping %d corpus files:\n", len(files))
	for _, file := range files {
		fmt.Printf("  %-12s %s\n", file, SkippedFiles[file])
	}
	fmt.Printf(
		"conformance: skipping %d cases inside included files "+
			"(conformance/skipped_cases.go)\n",
		len(skippedCases),
	)

	os.Exit(m.Run())
}

// TestSkipListCurrent keeps the committed skip list identical to what
// the generator derives from the corpus, so the two cannot drift.
func TestSkipListCurrent(t *testing.T) {
	want, err := GenerateSkippedCases()
	if err != nil {
		t.Fatal(err)
	}

	if RenderSkippedCases(want) != RenderSkippedCases(skippedCases) {
		t.Fatal(
			"skipped_cases.go is stale for this corpus checkout: " +
				"regenerate with: go run ./internal/cmd/skipgen",
		)
	}
}

// TestSimple runs the cel-spec simple conformance corpus. Subtests are
// named <file>/<section>/<case> so the single-file and single-case
// selectors work:
//
//	go test ./conformance/... -run TestSimple/basic
//	go test ./conformance/... -run TestSimple/basic/self_eval_zeroish/self_eval_int_zero
func TestSimple(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	// Probed once so a not-yet-implemented stage fails each case with
	// one clear line instead of thousands of undefined-function SQL
	// errors, and so a missing function can never masquerade as a CEL
	// error an eval_error case would spuriously pass on.
	stages, err := installedStages(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}

	files, err := corpus.Files()
	if err != nil {
		t.Fatal(err)
	}

	for _, file := range files {
		t.Run(file, func(t *testing.T) {
			if reason, ok := SkippedFiles[file]; ok {
				t.Skip(reason)
			}

			parsed, err := corpus.Load(file)
			if err != nil {
				t.Fatal(err)
			}

			for _, section := range parsed.GetSection() {
				t.Run(section.GetName(), func(t *testing.T) {
					for _, tc := range section.GetTest() {
						t.Run(tc.GetName(), func(t *testing.T) {
							runCase(t, ctx, conn, stages, file,
								section.GetName(), tc)
						})
					}
				})
			}
		})
	}
}

// stageSet records which cel.* entry points exist in the database, so
// failures name the missing stage rather than surfacing SQL errors.
type stageSet struct {
	parse, check, eval bool
}

func installedStages(
	ctx context.Context, conn *pgx.Conn,
) (stageSet, error) {
	var stages stageSet
	err := conn.QueryRow(ctx,
		`SELECT to_regprocedure('cel.parse(text, text)') IS NOT NULL,
		        to_regprocedure('cel.check(jsonb, text, jsonb)')
		            IS NOT NULL,
		        to_regprocedure('cel.eval(jsonb, jsonb, text)')
		            IS NOT NULL`,
	).Scan(&stages.parse, &stages.check, &stages.eval)
	if err != nil {
		return stages, fmt.Errorf("probe installed stages: %w", err)
	}
	return stages, nil
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

func runCase(
	t *testing.T,
	ctx context.Context,
	conn *pgx.Conn,
	stages stageSet,
	file, section string,
	tc *test.SimpleTest,
) {
	if reason := skipReason(file, section, tc.GetName()); reason != "" {
		t.Skip(reason)
	}

	env := EnvFor(file)

	// Parse.
	if !stages.parse {
		t.Fatal("parse stage: cel.parse(text, text) is not installed")
	}
	var raw []byte
	err := conn.QueryRow(ctx,
		"SELECT cel.parse($1, $2)", tc.GetExpr(), env,
	).Scan(&raw)
	if err != nil {
		t.Fatalf("parse stage: %v", err)
	}
	ast, err := codec.Decode(raw)
	if err != nil {
		t.Fatalf("parse stage: %v", err)
	}
	if errs, failed := stageErrors(ast); failed {
		if expectsError(tc) {
			return
		}
		t.Fatalf("parse stage: expression rejected: %v", errs)
	}

	// Check.
	if !tc.GetDisableCheck() {
		if !stages.check {
			t.Fatal(
				"check stage: cel.check(jsonb, text, jsonb) " +
					"is not installed",
			)
		}
		options, err := checkOptions(tc)
		if err != nil {
			t.Fatalf("check stage: %v", err)
		}
		err = conn.QueryRow(ctx,
			"SELECT cel.check($1, $2, $3)", raw, env, options,
		).Scan(&raw)
		if err != nil {
			t.Fatalf("check stage: %v", err)
		}
		ast, err = codec.Decode(raw)
		if err != nil {
			t.Fatalf("check stage: %v", err)
		}
		if errs, failed := stageErrors(ast); failed {
			if expectsError(tc) {
				return
			}
			t.Fatalf("check stage: expression rejected: %v", errs)
		}
	}

	if tc.GetCheckOnly() {
		compareDeducedType(t, ast, tc)
		return
	}

	// Eval.
	if !stages.eval {
		t.Fatal(
			"eval stage: cel.eval(jsonb, jsonb, text) is not installed",
		)
	}
	activation, err := activationJSON(tc)
	if err != nil {
		t.Fatalf("eval stage: %v", err)
	}
	var rawResult []byte
	err = conn.QueryRow(ctx,
		"SELECT cel.eval($1, $2, $3)", raw, activation, env,
	).Scan(&rawResult)
	if err != nil {
		t.Fatalf("eval stage: %v", err)
	}
	got, err := codec.Decode(rawResult)
	if err != nil {
		t.Fatalf("eval stage: %v", err)
	}

	compareResult(t, got, rawResult, tc)

	// typed_result compares the deduced type in addition to the value.
	if _, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult); ok {
		compareDeducedType(t, ast, tc)
	}
}

// checkOptions builds the options argument of cel.check (decision 7):
// the case's container and its type_env ident declarations.
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
// defaults to value: bool true (measured, workspace doc 01).
func compareResult(
	t *testing.T, got any, rawResult []byte, tc *test.SimpleTest,
) {
	switch matcher := tc.GetResultMatcher().(type) {
	case *test.SimpleTest_Value:
		want, err := codec.FromValue(matcher.Value)
		if err != nil {
			t.Fatalf("convert expected value: %v", err)
		}
		if !codec.Equal(want, got) {
			wantJSON, _ := json.Marshal(want)
			t.Fatalf("result mismatch:\n  want %s\n  got  %s",
				wantJSON, rawResult)
		}
	case *test.SimpleTest_EvalError:
		if kind, _ := taggedKind(got); kind != "error" {
			t.Fatalf("expected an error value, got %s", rawResult)
		}
	case *test.SimpleTest_TypedResult:
		want, err := codec.FromValue(matcher.TypedResult.GetResult())
		if err != nil {
			t.Fatalf("convert expected value: %v", err)
		}
		if !codec.Equal(want, got) {
			wantJSON, _ := json.Marshal(want)
			t.Fatalf("result mismatch:\n  want %s\n  got  %s",
				wantJSON, rawResult)
		}
	case nil:
		want := map[string]any{"@t": "bool", "v": true}
		if !codec.Equal(want, got) {
			t.Fatalf("expected bool true, got %s", rawResult)
		}
	default:
		// unknown / any_unknowns / any_eval_errors: zero corpus
		// cases use them today (measured); a corpus update that
		// introduces one must extend the runner, not pass silently.
		t.Fatalf("unsupported result matcher %T", matcher)
	}
}

// compareDeducedType compares the checked AST's root type against the
// typed_result matcher's deduced type (check_only cases,
// type_deduction file).
func compareDeducedType(t *testing.T, ast any, tc *test.SimpleTest) {
	typed, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult)
	if !ok {
		t.Fatalf("check_only case without typed_result matcher")
	}

	want, err := codec.FromType(typed.TypedResult.GetDeducedType())
	if err != nil {
		t.Fatalf("convert expected type: %v", err)
	}

	envelope, ok := ast.(map[string]any)
	if !ok {
		t.Fatalf("checked AST is not an object")
	}
	root, ok := envelope["expr"].(map[string]any)
	if !ok {
		t.Fatalf("checked AST has no root expression")
	}
	rootID, ok := root["id"].(json.Number)
	if !ok {
		t.Fatalf("root expression has no id")
	}
	types, ok := envelope["types"].(map[string]any)
	if !ok {
		t.Fatalf("AST is not checked: no types map")
	}

	got := types[rootID.String()]
	wantJSON, _ := json.Marshal(want)
	gotJSON, _ := json.Marshal(got)
	if string(wantJSON) != string(gotJSON) {
		t.Fatalf("deduced type mismatch:\n  want %s\n  got  %s",
			wantJSON, gotJSON)
	}
}

func taggedKind(v any) (string, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", false
	}
	kind, ok := m["@t"].(string)
	return kind, ok
}
