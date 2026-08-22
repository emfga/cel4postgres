// Package testdb resolves the test database connection for the Go
// suites.
//
// The connection is described once, in .env, as POSTGRES_* variables
// that compose also reads. Keeping a second copy of them in a
// DATABASE_URL is how a changed port silently stops applying to half
// the tooling, so the DSN is derived here instead. An explicit
// DATABASE_URL in the environment still wins -- that is how the
// containerised `test` service in compose.yaml points at the
// service-network host rather than at localhost.
package testdb

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/cel4postgres/internal/repo"
)

// DSN is the connection string for the test database.
func DSN() (string, error) {
	env, err := loadEnv()
	if err != nil {
		return "", err
	}

	if dsn := env["DATABASE_URL"]; dsn != "" {
		return dsn, nil
	}

	missing := []string{}
	get := func(key string) string {
		value := env[key]
		if value == "" {
			missing = append(missing, key)
		}
		return value
	}

	user := get("POSTGRES_USER")
	password := get("POSTGRES_PASSWORD")
	host := get("POSTGRES_HOST")
	port := get("POSTGRES_PORT")
	database := get("POSTGRES_DB")

	if len(missing) > 0 {
		return "", fmt.Errorf(
			"missing %s: set them in .env (copy .env.example) or in the environment",
			strings.Join(missing, ", "),
		)
	}

	return (&url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(user, password),
		Host:     net.JoinHostPort(host, port),
		Path:     "/" + database,
		RawQuery: "sslmode=disable",
	}).String(), nil
}

// Connect opens a connection to the test database.
//
// The error names the command that fixes the common cause, because
// the common cause is that nobody started the database.
func Connect(ctx context.Context) (*pgx.Conn, error) {
	dsn, err := DSN()
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf(
			"connect to the test database: %w\n"+
				"Is it running? Start it with: docker compose up -d --wait",
			err,
		)
	}

	return conn, nil
}

// loadEnv returns the process environment overlaid on the repo's .env
// file. Process environment wins, so CI needs no file at all.
func loadEnv() (map[string]string, error) {
	env := map[string]string{}

	root, err := repo.Root()
	if err != nil {
		return nil, err
	}

	file, err := os.Open(filepath.Join(root, ".env"))
	if err == nil {
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
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("open .env: %w", err)
	}

	for _, key := range []string{
		"DATABASE_URL",
		"POSTGRES_DB",
		"POSTGRES_HOST",
		"POSTGRES_PASSWORD",
		"POSTGRES_PORT",
		"POSTGRES_USER",
	} {
		if value, ok := os.LookupEnv(key); ok && value != "" {
			env[key] = value
		}
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
