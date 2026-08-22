package oracle

import (
	"fmt"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

// envOptions maps cel4postgres env names to the cel-go options that
// build the equivalent reference environment. "standard" is the base
// cel.NewEnv (standard library and macros) plus identifier-escape
// syntax, which cel-go's conformance run enables for the whole corpus
// and our standard env includes (workspace doc 01).
var envOptions = map[string][]cel.EnvOption{
	// Cross-type numeric comparisons and error-on-bad-presence-test
	// are cel-go options, but the conformance corpus requires both
	// under its plain standard environment (cel-go's own harness
	// enables them globally, conformance_test.go:82-97), so our
	// standard env includes them and the oracle must match.
	"standard": {
		cel.EnableIdentifierEscapeSyntax(),
		cel.CrossTypeNumericComparisons(true),
		cel.EnableErrorOnBadPresenceTest(true),
	},
	"strings":  {ext.Strings()},
	"math":     {ext.Math()},
	"lists":    {ext.Lists()},
	"encoders": {ext.Encoders()},
	"bindings": {ext.Bindings()},
	"optionals": {
		cel.OptionalTypes(),
	},
	"two_var_comprehensions": {ext.TwoVarComprehensions()},
	"network":                {ext.Network()},
}

// Options resolves a comma-separated env-name union -- the same string
// cel.parse/check/eval take -- to cel-go options, so a disputed case
// runs against the reference under the same environment composition
// our side used. An unknown name is an error, not a silent no-op: an
// oracle configured differently than the evaluator measures nothing.
func Options(env string) ([]cel.EnvOption, error) {
	options := []cel.EnvOption{}
	for name := range strings.SplitSeq(env, ",") {
		name = strings.TrimSpace(name)
		resolved, ok := envOptions[name]
		if !ok {
			return nil, fmt.Errorf("no cel-go options for env %q", name)
		}
		options = append(options, resolved...)
	}
	return options, nil
}
