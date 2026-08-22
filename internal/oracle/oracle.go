// Package oracle wraps cel-go, the behavioural reference cel4postgres
// is measured against.
//
// It exists so that exactly one place in the tree constructs a cel-go
// environment. Conformance is a comparison between two evaluators, and
// a comparison is only meaningful if the reference side is configured
// identically for every case -- an env assembled ad hoc at each call
// site is a way to accidentally measure two different references.
//
// The environment here is deliberately bare: the standard library and
// standard macros, nothing else. Extension libraries are opt-in per
// test file, mirroring how cel-go's own conformance runner enables
// them selectively, because a file that passes only because an
// extension leaked into the default environment is not a passing file.
package oracle

import (
	"fmt"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types/ref"
)

// Version is the cel-go release this project is measured against.
//
// It is pinned exactly in go.mod and stays exactly pinned: the set of
// expressions cel-go and cel4postgres agree on moves with the cel-go
// version, so an upgrade is a deliberate change that re-measures
// conformance, never a routine bump. This constant exists so a test
// can assert the two have not drifted apart.
const Version = "v0.32.0"

// Env returns a CEL environment carrying only the standard library.
func Env(options ...cel.EnvOption) (*cel.Env, error) {
	env, err := cel.NewEnv(options...)
	if err != nil {
		return nil, fmt.Errorf("build cel-go environment: %w", err)
	}

	return env, nil
}

// Eval compiles and evaluates an expression against the reference
// implementation, with the given activation.
//
// Compile errors and evaluation errors are returned distinctly because
// CEL treats them as different outcomes and the conformance corpus
// asserts against each separately: an expression the checker rejects
// is not the same result as one that evaluates to an error.
func Eval(
	expression string,
	activation map[string]any,
	options ...cel.EnvOption,
) (ref.Val, error) {
	env, err := Env(options...)
	if err != nil {
		return nil, err
	}

	ast, issues := env.Compile(expression)
	if issues != nil && issues.Err() != nil {
		return nil, fmt.Errorf("compile %q: %w", expression, issues.Err())
	}

	program, err := env.Program(ast)
	if err != nil {
		return nil, fmt.Errorf("plan %q: %w", expression, err)
	}

	if activation == nil {
		activation = map[string]any{}
	}

	value, _, err := program.Eval(activation)
	if err != nil {
		return nil, fmt.Errorf("evaluate %q: %w", expression, err)
	}

	return value, nil
}
