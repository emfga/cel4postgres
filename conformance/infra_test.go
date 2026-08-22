// Package conformance holds the suite that measures cel4postgres
// against the cel-spec conformance corpus.
//
// Nothing here reads a .textproto yet. These are the infrastructure
// tests: they fail loudly when the database is missing or the schema
// was never installed, so that a later red conformance run is never
// ambiguous about which of the two went wrong.
package conformance

import (
	"context"
	"testing"

	"github.com/emfga/cel4postgres/internal/testdb"
)

func TestDatabaseReachable(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	var ok bool
	if err := conn.QueryRow(ctx, "SELECT true").Scan(&ok); err != nil {
		t.Fatalf("SELECT true: %v", err)
	}

	if !ok {
		t.Fatal("SELECT true returned false")
	}
}

func TestSchemaInstalled(t *testing.T) {
	ctx := context.Background()

	conn, err := testdb.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	var version string
	err = conn.QueryRow(ctx, "SELECT cel.version()").Scan(&version)
	if err != nil {
		t.Fatalf(
			"SELECT cel.version(): %v\n"+
				"Is the schema installed? Install it with: "+
				"docker compose up -d --wait",
			err,
		)
	}

	if version == "" {
		t.Fatal("cel.version() returned an empty version")
	}

	t.Logf("cel schema version %s", version)
}
