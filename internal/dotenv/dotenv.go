// Package dotenv reads configuration the way the whole toolchain
// agrees to: the process environment first, then the repo's .env file.
//
// Compose reads .env from the repo root automatically; keeping the Go
// suites on the same file means a value changed there applies to both
// sides, and CI -- which exports everything in the process environment
// -- needs no file at all.
package dotenv

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/emfga/cel4postgres/internal/repo"
)

// Lookup returns the value for key, preferring the process
// environment over the repo's .env file. A missing key returns "".
func Lookup(key string) (string, error) {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value, nil
	}

	env, err := load()
	if err != nil {
		return "", err
	}

	return env[key], nil
}

// load parses the repo's .env file. A missing file is not an error --
// every variable has a default or arrives via the environment.
func load() (map[string]string, error) {
	env := map[string]string{}

	root, err := repo.Root()
	if err != nil {
		return nil, err
	}

	file, err := os.Open(filepath.Join(root, ".env"))
	if os.IsNotExist(err) {
		return env, nil
	}
	if err != nil {
		return nil, fmt.Errorf("open .env: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		key, value, ok := parseLine(scanner.Text())
		if ok {
			env[key] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read .env: %w", err)
	}

	return env, nil
}

// parseLine reads one KEY=VALUE line, ignoring comments and blanks.
func parseLine(line string) (string, string, bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false
	}

	key, value, ok := strings.Cut(line, "=")
	if !ok {
		return "", "", false
	}

	key = strings.TrimSpace(strings.TrimPrefix(key, "export "))
	value = strings.TrimSpace(value)
	value = strings.Trim(value, `"'`)

	return key, value, key != ""
}
