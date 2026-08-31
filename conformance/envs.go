package conformance

// fileEnvs names the environment each corpus file runs under, as a
// comma-separated union of registered env names. Files absent here run
// under plain "standard". Extension files enable exactly the extension
// they exercise and nothing more: a file that passes only because the
// default environment quietly gained an extension is not a passing
// file.
//
// macros2 was measured: every one of its 46 cases uses the
// two-var comprehension macros and none uses optional syntax, so the
// whole file takes two_var_comprehensions and nothing else.
var fileEnvs = map[string]string{
	"string_ext":   "standard,strings",
	"math_ext":     "standard,math",
	"lists_ext":    "standard,lists",
	"encoders_ext": "standard,encoders",
	"bindings_ext": "standard,bindings",
	"optionals":    "standard,optionals",
	"macros2":      "standard,two_var_comprehensions",
	"network_ext":  "standard,network",
	// type_deduction's flexible_type_parameter_assignment and
	// legacy_nullable_types sections deduce optional_type values;
	// everything else in the file is standard.
	"type_deduction": "standard,optionals",
}

// EnvFor returns the env parameter for a corpus file.
func EnvFor(file string) string {
	if env, ok := fileEnvs[file]; ok {
		return env
	}
	return "standard"
}
