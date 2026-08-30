package oracle

import (
	"fmt"

	expr "cel.dev/expr"
	test "cel.dev/expr/conformance/test"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
)

// Running a whole conformance case against cel-go -- rather than a
// bare expression -- is what lets the two implementations be compared
// case by case for the conformance report. The recipe mirrors cel-go's
// own harness (conformance/conformance_test.go): declarations and
// container come from the case, macros are cleared when the case says
// so, and check runs unless the case disables it.

// Outcome is what cel-go produced for one corpus case.
//
// Err carries a CEL-level outcome -- an expression cel-go rejected, or
// one that evaluated to an error -- which the corpus asserts on with
// eval_error. It is not a harness failure; those are returned as the
// second result of RunCase.
type Outcome struct {
	Value *expr.Value
	Type  *expr.Type
	Err   error
}

// RunCase compiles and evaluates one corpus case against cel-go under
// the given cel4postgres env name, so both sides of the comparison see
// the same environment composition.
func RunCase(tc *test.SimpleTest, envName string) (Outcome, error) {
	options, err := Options(envName)
	if err != nil {
		return Outcome{}, err
	}
	if tc.GetDisableMacros() {
		options = append(options, cel.ClearMacros())
	}
	if container := tc.GetContainer(); container != "" {
		options = append(options, cel.Container(container))
	}
	for _, decl := range tc.GetTypeEnv() {
		option, err := cel.ProtoAsDeclaration(decl)
		if err != nil {
			return Outcome{}, fmt.Errorf(
				"declaration %q: %w", decl.GetName(), err)
		}
		options = append(options, option)
	}

	env, err := Env(options...)
	if err != nil {
		return Outcome{}, err
	}

	ast, issues := env.Parse(tc.GetExpr())
	if issues != nil && issues.Err() != nil {
		return Outcome{Err: issues.Err()}, nil
	}

	if !tc.GetDisableCheck() {
		ast, issues = env.Check(ast)
		if issues != nil && issues.Err() != nil {
			return Outcome{Err: issues.Err()}, nil
		}
	}

	outcome := Outcome{}
	if !tc.GetDisableCheck() {
		deduced, err := types.TypeToProto(ast.OutputType())
		if err != nil {
			return Outcome{}, fmt.Errorf("deduced type: %w", err)
		}
		outcome.Type = deduced
	}
	if tc.GetCheckOnly() {
		return outcome, nil
	}

	// A planning failure is cel-go refusing the expression -- an
	// unsupported map key type is reported here rather than at eval
	// -- so it is a CEL-level outcome the corpus asserts on with
	// eval_error, not a harness failure.
	program, err := env.Program(ast)
	if err != nil {
		return Outcome{Type: outcome.Type, Err: err}, nil
	}

	activation := map[string]any{}
	for name, binding := range tc.GetBindings() {
		value, err := bindingValue(env, binding)
		if err != nil {
			return Outcome{}, fmt.Errorf("binding %q: %w", name, err)
		}
		activation[name] = value
	}

	result, _, err := program.Eval(activation)
	if err != nil {
		return Outcome{Type: outcome.Type, Err: err}, nil
	}
	if types.IsError(result) {
		return Outcome{
			Type: outcome.Type,
			Err:  result.(*types.Err).Unwrap(),
		}, nil
	}

	value, err := cel.ValueAsProto(result)
	if err != nil {
		return Outcome{}, fmt.Errorf("convert result: %w", err)
	}
	outcome.Value = value
	return outcome, nil
}

// bindingValue converts a case binding to a cel-go value. Only the
// value kind occurs in the corpus (measured); an error or unknown
// binding is reported rather than guessed at, so a corpus update that
// introduces one extends this deliberately.
func bindingValue(env *cel.Env, v *expr.ExprValue) (any, error) {
	value, ok := v.GetKind().(*expr.ExprValue_Value)
	if !ok {
		return nil, fmt.Errorf("unsupported binding kind %T", v.GetKind())
	}
	return cel.ProtoAsValue(env.CELTypeAdapter(), value.Value)
}
