// Package store is the per-connection SQLCipher database: the connection's
// metadata (its callback secret), the outbox of events not yet acknowledged
// by Rails, and whatsmeow's own session tables (whatsmeow_*), which
// whatsmeow creates on the same *sql.DB through sqlstore.NewWithDB. One
// encrypted file per connection.
//
// Rules from the slice 0 probe (§6b):
//   - the key goes in the DSN, applied inside the driver's Open before any
//     page is read; never in the ConnectHook (that breaks every reopen);
//   - the ConnectHook sets the per-connection pragmas on every pooled
//     connection;
//   - the DSN never reaches a log, an error or a %v: it lives only inside
//     keyedConnector, whose formatting is redacted, and every open error is
//     replaced by ErrOpen.
package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	sqlite3 "github.com/mattn/go-sqlite3" // replaced by jgiannuzzi/go-sqlite3 (sqlite3mc 2.2.7), see go.mod
)

// DriverName is the registered driver. whatsmeow's dbutil maps any name
// starting with "sqlite" to the SQLite dialect, which slice 4 relies on.
const DriverName = "sqlite3-comms"

var (
	// ErrOpen is the only error Open returns. The driver's own errors are
	// discarded because the open path is where the DSN is parsed.
	ErrOpen = errors.New("open comms store failed")
	// ErrStore is returned for any later database failure.
	ErrStore = errors.New("comms store operation failed")
	// ErrBadInput is returned for rows that fail validation before writing.
	ErrBadInput = errors.New("invalid store input")
)

// connectPragmas run on every pooled connection, after the driver has
// applied the key.
var connectPragmas = []string{
	"PRAGMA foreign_keys = ON",
	"PRAGMA journal_mode = WAL",
	"PRAGMA temp_store = MEMORY",
	"PRAGMA secure_delete = ON",
	"PRAGMA synchronous = FULL",
	"PRAGMA busy_timeout = 5000",
}

var (
	registerOnce sync.Once
	registered   driver.Driver
)

func cipherDriver() driver.Driver {
	registerOnce.Do(func() {
		d := &sqlite3.SQLiteDriver{
			ConnectHook: func(c *sqlite3.SQLiteConn) error {
				for _, p := range connectPragmas {
					if _, err := c.Exec(p, nil); err != nil {
						return errHook
					}
				}
				return nil
			},
		}
		sql.Register(DriverName, d)
		registered = d
	})
	return registered
}

var errHook = errors.New("connection setup failed")

// keyedConnector opens connections with the DSN. The DSN exists only inside
// the open closure: fmt prints a func as an address and never looks inside
// it. (A plain string field is not enough: fmt's bad-verb path, e.g.
// fmt.Sprintf("%s", db) on the *sql.DB, dereferences the connector struct and
// prints unexported fields, bypassing any Format method.)
type keyedConnector struct {
	open func() (driver.Conn, error)
	d    driver.Driver
}

func newKeyedConnector(dsn string, d driver.Driver) keyedConnector {
	return keyedConnector{
		open: func() (driver.Conn, error) { return d.Open(dsn) },
		d:    d,
	}
}

func (k keyedConnector) Connect(context.Context) (driver.Conn, error) {
	c, err := k.open()
	if err != nil {
		return nil, ErrOpen
	}
	return c, nil
}
func (k keyedConnector) Driver() driver.Driver    { return k.d }
func (keyedConnector) String() string             { return "comms-store-connector" }
func (keyedConnector) GoString() string           { return "comms-store-connector" }
func (keyedConnector) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("comms-store-connector")) }

// Store is one open per-connection database.
type Store struct {
	db *sql.DB
}

func (s *Store) String() string             { return "comms-store" }
func (s *Store) GoString() string           { return "comms-store" }
func (s *Store) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("comms-store")) }

func buildDSN(path string, key []byte) (string, bool) {
	// No "file:" prefix: the driver then passes only the path (everything
	// before '?') to sqlite3_open_v2, so the key never becomes part of the
	// SQLite filename/URI.
	if path == "" || strings.ContainsAny(path, "?#") || strings.HasPrefix(path, "file:") || len(key) != 32 {
		return "", false
	}
	q := "_cipher=sqlcipher&_legacy=4" +
		"&_key=" + url.QueryEscape("x'"+hex.EncodeToString(key)+"'") +
		"&_sync=FULL&_txlock=immediate&_busy_timeout=5000"
	return path + "?" + q, true
}

// Open opens (creating if needed) the encrypted store at path with a 32-byte
// SQLCipher key. A wrong key, a plaintext file, a build without
// SQLITE_TEMP_STORE=3 or any pragma that did not take all yield ErrOpen.
func Open(ctx context.Context, path string, key []byte) (*Store, error) {
	dsn, ok := buildDSN(path, key)
	if !ok {
		return nil, ErrOpen
	}
	db := sql.OpenDB(newKeyedConnector(dsn, cipherDriver()))
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	s := &Store{db: db}
	if err := s.init(ctx); err != nil {
		db.Close()
		return nil, ErrOpen
	}
	return s, nil
}

func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return ErrStore
	}
	return nil
}

const schema = `
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS outbox (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  body      BLOB NOT NULL,
  queued_at INTEGER NOT NULL
);
`

func (s *Store) init(ctx context.Context) error {
	// Touch the database first: with a wrong key this is where it fails.
	var n int
	if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM sqlite_master").Scan(&n); err != nil {
		return err
	}
	if err := s.checkBuild(ctx); err != nil {
		return err
	}
	if err := s.CheckPragmas(ctx); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, schema)
	return err
}

// checkBuild refuses a binary compiled without -DSQLITE_TEMP_STORE=3.
func (s *Store) checkBuild(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, "PRAGMA compile_options")
	if err != nil {
		return err
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var opt string
		if err := rows.Scan(&opt); err != nil {
			return err
		}
		if opt == "TEMP_STORE=3" {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !found {
		return errors.New("built without SQLITE_TEMP_STORE=3")
	}
	return nil
}

// Pragmas is what one pooled connection reports.
type Pragmas struct {
	ForeignKeys  int
	JournalMode  string
	TempStore    int
	SecureDelete int
	Synchronous  int
}

// ConnPragmas reads the pragmas on one specific pooled connection.
func ConnPragmas(ctx context.Context, c *sql.Conn) (Pragmas, error) {
	var p Pragmas
	q := func(stmt string, dst any) error { return c.QueryRowContext(ctx, stmt).Scan(dst) }
	if err := q("PRAGMA foreign_keys", &p.ForeignKeys); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA journal_mode", &p.JournalMode); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA temp_store", &p.TempStore); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA secure_delete", &p.SecureDelete); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA synchronous", &p.Synchronous); err != nil {
		return p, ErrStore
	}
	return p, nil
}

// Want is the required pragma state of every connection.
var Want = Pragmas{ForeignKeys: 1, JournalMode: "wal", TempStore: 2, SecureDelete: 1, Synchronous: 2}

// CheckPragmas verifies Want on one pooled connection.
func (s *Store) CheckPragmas(ctx context.Context) error {
	c, err := s.db.Conn(ctx)
	if err != nil {
		return ErrStore
	}
	defer c.Close()
	p, err := ConnPragmas(ctx, c)
	if err != nil {
		return err
	}
	if p != Want {
		return errors.New("pragma state not as required")
	}
	return nil
}

// Conn exposes one pooled connection (tests use it to check every connection).
func (s *Store) Conn(ctx context.Context) (*sql.Conn, error) {
	c, err := s.db.Conn(ctx)
	if err != nil {
		return nil, ErrStore
	}
	return c, nil
}

// DB is the encrypted database for whatsmeow's sqlstore.NewWithDB. Its DSN
// cannot be printed (see keyedConnector).
func (s *Store) DB() *sql.DB { return s.db }

// Meta reads one metadata value; ok is false when it is absent.
func (s *Store) Meta(ctx context.Context, key string) (value string, ok bool, err error) {
	err = s.db.QueryRowContext(ctx, `SELECT value FROM meta WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, ErrStore
	}
	return value, true, nil
}

// SetMeta writes metadata values in one transaction.
func (s *Store) SetMeta(ctx context.Context, kv map[string]string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ErrStore
	}
	defer tx.Rollback()
	for k, v := range kv {
		if k == "" {
			return ErrBadInput
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO meta (key, value) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`, k, v); err != nil {
			return ErrStore
		}
	}
	if tx.Commit() != nil {
		return ErrStore
	}
	return nil
}

// OutboxEvent is one event waiting for Rails' acknowledgement. ID is local
// and strictly increasing; the wire sequence is derived from it.
type OutboxEvent struct {
	ID   int64
	Body []byte
}

// Enqueue appends events to the outbox in one transaction, in order.
func (s *Store) Enqueue(ctx context.Context, bodies ...[]byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ErrStore
	}
	defer tx.Rollback()
	now := time.Now().UnixMilli()
	for _, b := range bodies {
		if len(b) == 0 {
			return ErrBadInput
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO outbox (body, queued_at) VALUES (?, ?)`, b, now); err != nil {
			return ErrStore
		}
	}
	if tx.Commit() != nil {
		return ErrStore
	}
	return nil
}

// Pending returns up to limit undelivered events, oldest first.
func (s *Store) Pending(ctx context.Context, limit int) ([]OutboxEvent, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, body FROM outbox ORDER BY id LIMIT ?`, limit)
	if err != nil {
		return nil, ErrStore
	}
	defer rows.Close()
	var out []OutboxEvent
	for rows.Next() {
		var e OutboxEvent
		if err := rows.Scan(&e.ID, &e.Body); err != nil {
			return nil, ErrStore
		}
		out = append(out, e)
	}
	if rows.Err() != nil {
		return nil, ErrStore
	}
	return out, nil
}

// Delivered drops every event up to and including id. secure_delete is on,
// so the freed pages are zeroed.
func (s *Store) Delivered(ctx context.Context, id int64) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM outbox WHERE id <= ?`, id); err != nil {
		return ErrStore
	}
	return nil
}

// Drop removes one event without delivering it.
func (s *Store) Drop(ctx context.Context, id int64) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM outbox WHERE id = ?`, id); err != nil {
		return ErrStore
	}
	return nil
}

// OutboxDepth counts undelivered events.
func (s *Store) OutboxDepth(ctx context.Context) (int, error) {
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT count(*) FROM outbox`).Scan(&n); err != nil {
		return 0, ErrStore
	}
	return n, nil
}

// Remove deletes a closed store's files: the database, its WAL and shared
// memory. A missing file is not an error.
func Remove(path string) error {
	for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
		if err := os.Remove(path + suffix); err != nil && !errors.Is(err, os.ErrNotExist) {
			return ErrStore
		}
	}
	return nil
}
