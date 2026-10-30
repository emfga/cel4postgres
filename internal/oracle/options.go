package oracle

import (
	"fmt"
	"sort"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
)

// envOptions maps cel4postgres env names to the cel-go options that
// build the equivalent reference environment. "standard" is the base
// cel.NewEnv (standard library and macros) plus identifier-escape
// syntax, which cel-go's conformance run enables for the whole corpus
// and our standard env includes.
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
	// Every library runs at its latest version, as cel4postgres
	// implements it, except encoders: its version 2 adds json.parse
	// and yaml.encode / yaml.parse, which sql/ does not implement
	// (docs/CONFORMANCE.md), so it is held at 2 rather than left to
	// grow on the next cel-go bump. TestLibraryOverloads names what
	// each env lacks against this configuration.
	"strings":  {ext.Strings()},
	"math":     {ext.Math()},
	"lists":    {ext.Lists()},
	"encoders": {ext.Encoders(ext.EncodersVersion(2))},
	"bindings": {ext.Bindings()},
	"optionals": {
		cel.OptionalTypes(),
	},
	"two_var_comprehensions": {ext.TwoVarComprehensions()},
	"network":                {ext.Network()},
}

// EnvNames returns every env name the oracle can configure, sorted.
func EnvNames() []string {
	names := make([]string, 0, len(envOptions))
	for name := range envOptions {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
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

// OverloadIDs returns the overload ids a comma-separated env union
// declares in cel-go, so the registry can be checked against the
// reference overload for overload, not only case by case: the
// corpus exercises a fraction of each library, and a function it
// never calls would otherwise go missing unnoticed.
func OverloadIDs(env string) (map[string]bool, error) {
	options, err := Options(env)
	if err != nil {
		return nil, err
	}
	celEnv, err := Env(options...)
	if err != nil {
		return nil, err
	}
	ids := map[string]bool{}
	for _, fn := range celEnv.Functions() {
		for _, o := range fn.OverloadDecls() {
			ids[o.ID()] = true
		}
	}
	return ids, nil
}
