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
	"context"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/cel4postgres/internal/dotenv"
)

// DSN is the connection string for the test database.
func DSN() (string, error) {
	if dsn, err := dotenv.Lookup("DATABASE_URL"); err != nil {
		return "", err
	} else if dsn != "" {
		return dsn, nil
	}

	missing := []string{}
	var lookupErr error
	get := func(key string) string {
		value, err := dotenv.Lookup(key)
		if err != nil {
			lookupErr = err
		}
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

	if lookupErr != nil {
		return "", lookupErr
	}
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
