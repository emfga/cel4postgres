package conformance

import (
	"encoding/json"
	"fmt"

	test "cel.dev/expr/conformance/test"

	"github.com/emfga/cel4postgres/internal/codec"
	"github.com/emfga/cel4postgres/internal/oracle"
)

// The conformance report names every case where cel4postgres and
// cel-go disagree. Both verdicts have to be reached the same way for
// that to mean anything, so the oracle's outcome is judged by the
// comparators the database side is judged by -- the only difference is
// where the value came from.

// RunOracleCase runs one corpus case against cel-go and compares the
// outcome to the corpus expectation, under the same env the database
// side uses.
func RunOracleCase(
	file, section string, tc *test.SimpleTest,
) CaseResult {
	result := CaseResult{File: file, Section: section, Name: tc.GetName()}

	if reason := skipReason(file, section, tc.GetName()); reason != "" {
		result.Status = Skipped
		result.Detail = reason
		return result
	}

	status, detail := runOracleCase(file, tc)
	result.Status = status
	result.Detail = detail
	return result
}

func runOracleCase(file string, tc *test.SimpleTest) (Status, string) {
	fail := func(format string, args ...any) (Status, string) {
		return Failed, fmt.Sprintf(format, args...)
	}

	outcome, err := oracle.RunCase(tc, EnvFor(file))
	if err != nil {
		return fail("oracle: %v", err)
	}

	if outcome.Err != nil {
		if expectsError(tc) {
			return Passed, ""
		}
		return fail("cel-go rejected the case: %v", outcome.Err)
	}

	if tc.GetCheckOnly() {
		if err := compareOracleType(outcome, tc); err != nil {
			return fail("%v", err)
		}
		return Passed, ""
	}

	got, err := codec.FromValue(outcome.Value)
	if err != nil {
		return fail("oracle: convert result: %v", err)
	}
	rendered, _ := json.Marshal(got)

	if err := compareResult(got, rendered, tc); err != nil {
		return fail("%v", err)
	}

	if _, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult); ok {
		if err := compareOracleType(outcome, tc); err != nil {
			return fail("%v", err)
		}
	}

	return Passed, ""
}

func compareOracleType(
	outcome oracle.Outcome, tc *test.SimpleTest,
) error {
	typed, ok := tc.GetResultMatcher().(*test.SimpleTest_TypedResult)
	if !ok {
		return fmt.Errorf("check_only case without typed_result matcher")
	}

	want, err := codec.FromType(typed.TypedResult.GetDeducedType())
	if err != nil {
		return fmt.Errorf("convert expected type: %w", err)
	}
	got, err := codec.FromType(outcome.Type)
	if err != nil {
		return fmt.Errorf("convert deduced type: %w", err)
	}

	return compareTypeJSON(want, got)
}
