// Package corpus locates and parses the cel-spec conformance corpus.
//
// The corpus is the set of SimpleTestFile textprotos under
// cel-spec/tests/simple/testdata in a local cel-spec checkout. The
// checkout lives under a per-machine path named by CEL_EXPR_DIR
// (environment or .env), never hard-coded, so a fresh clone on another
// machine configures it once.
package corpus

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	expr "cel.dev/expr"
	test "cel.dev/expr/conformance/test"
	"google.golang.org/protobuf/encoding/prototext"

	"github.com/emfga/cel4postgres/internal/dotenv"

	// The textprotos spell google.protobuf.Any fields in expanded
	// form, so parsing them needs the cel.expr.conformance.proto2/3
	// descriptors registered. Test-harness-only: nothing in the
	// cel4postgres runtime touches protobuf descriptors.
	_ "cel.dev/expr/conformance/proto2"
	_ "cel.dev/expr/conformance/proto3"
)

// Pin is the cel-spec commit the conformance corpus is measured at.
//
// It is pinned for the same reason cel-go is: the corpus defines what
// a conformance number means, so it moves only deliberately, with a
// re-measurement behind it. CI checks the corpus out at this commit
// and the conformance report prints it, so this constant is the one
// place the pin is written down -- a test keeps the workflow honest.
const Pin = "ba58ae5007845f3a1279b488cdeb79645ce958bb"

// Checkout returns the root of the local cel-spec checkout, or an
// error naming the variable that fixes a missing configuration.
func Checkout() (string, error) {
	root, err := dotenv.Lookup("CEL_EXPR_DIR")
	if err != nil {
		return "", err
	}
	if root == "" {
		return "", fmt.Errorf(
			"CEL_EXPR_DIR is not set: point it at the directory " +
				"holding the cel-spec/cel-go/cel-java checkouts " +
				"(environment or .env)",
		)
	}

	return filepath.Join(root, "cel-spec"), nil
}

// Dir returns the testdata directory of the cel-spec checkout, or an
// error naming the variable that fixes a missing configuration.
func Dir() (string, error) {
	checkout, err := Checkout()
	if err != nil {
		return "", err
	}

	dir := filepath.Join(checkout, "tests", "simple", "testdata")
	if _, err := os.Stat(dir); err != nil {
		return "", fmt.Errorf(
			"conformance corpus not found at %s: is CEL_EXPR_DIR "+
				"pointing at a directory with a cel-spec checkout? (%w)",
			dir, err,
		)
	}

	return dir, nil
}

// HeadSHA returns the commit the local cel-spec checkout sits at, or
// "" when that cannot be determined -- a checkout unpacked from an
// archive rather than cloned has no commit to report, and that is a
// working configuration, not an error. Callers report the difference
// rather than failing on it.
func HeadSHA() (string, error) {
	checkout, err := Checkout()
	if err != nil {
		return "", err
	}

	out, err := exec.Command(
		"git", "-C", checkout, "rev-parse", "HEAD",
	).Output()
	if err != nil {
		return "", nil
	}

	return strings.TrimSpace(string(out)), nil
}

// Files returns the corpus file names (without extension), sorted.
func Files() ([]string, error) {
	dir, err := Dir()
	if err != nil {
		return nil, err
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read corpus directory: %w", err)
	}

	names := []string{}
	for _, entry := range entries {
		if name, ok := strings.CutSuffix(entry.Name(), ".textproto"); ok {
			names = append(names, name)
		}
	}
	sort.Strings(names)

	return names, nil
}

// Load parses one corpus file by name (without extension).
func Load(name string) (*test.SimpleTestFile, error) {
	dir, err := Dir()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(filepath.Join(dir, name+".textproto"))
	if err != nil {
		return nil, fmt.Errorf("read corpus file: %w", err)
	}

	file := &test.SimpleTestFile{}
	if err := prototext.Unmarshal(data, file); err != nil {
		return nil, fmt.Errorf("parse %s.textproto: %w", name, err)
	}

	return file, nil
}

// descriptorDependent matches the message names whose cases need real
// protobuf descriptors: TestAllTypes-family constructions, proto2
// extensions, and Any packed around serialized proto payloads. The
// package path also covers container strings, type_env declarations
// and Any type URLs, which all spell it out in full.
var descriptorDependent = regexp.MustCompile(
	`cel\.expr\.conformance\.proto[23]` +
		`|TestAllTypes|NestedTestAllTypes|Proto2ExtensionScopedMessage`,
)

// DescriptorDependent reports whether a test case requires protobuf
// descriptors, by scanning its full textproto rendering for the
// message names of the conformance proto2/proto3 test schemas. Scanned
// mechanically, never listed by hand, so the skip list cannot drift
// from the corpus.
func DescriptorDependent(t *test.SimpleTest) bool {
	return descriptorDependent.MatchString(prototext.Format(t))
}

// ContainsNulString reports whether the case's expected value or
// bindings carry a string (not bytes) containing NUL. PostgreSQL text
// and jsonb strings categorically cannot represent U+0000, so these
// cases are skipped by name -- a substrate limitation, not a CEL one.
// A raw-string literal like r'\000' is unaffected: its value holds
// the backslash characters, not a NUL.
func ContainsNulString(t *test.SimpleTest) bool {
	// Some comparison cases carry raw NUL bytes inside the expression
	// text itself (bytes literals written verbatim in the textproto);
	// those cannot even be sent to Postgres as a text parameter.
	if strings.ContainsRune(t.GetExpr(), 0) {
		return true
	}
	for _, binding := range t.GetBindings() {
		if exprValueHasNul(binding) {
			return true
		}
	}
	return valueHasNul(t.GetValue()) ||
		valueHasNul(t.GetTypedResult().GetResult())
}

func exprValueHasNul(v *expr.ExprValue) bool {
	return valueHasNul(v.GetValue())
}

func valueHasNul(v *expr.Value) bool {
	if v == nil {
		return false
	}
	if strings.ContainsRune(v.GetStringValue(), 0) {
		return true
	}
	if slices.ContainsFunc(v.GetListValue().GetValues(), valueHasNul) {
		return true
	}
	for _, e := range v.GetMapValue().GetEntries() {
		if valueHasNul(e.GetKey()) || valueHasNul(e.GetValue()) {
			return true
		}
	}
	return false
}
