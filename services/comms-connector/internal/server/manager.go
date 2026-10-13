// Package server is the connector's command side: the manager that owns one
// worker per connection, and the mutual-TLS HTTP handler for Rails's two
// commands, start_pairing and unpair.
package server

import (
	"context"
	"log/slog"
	"os"
	"sync"

	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/worker"
)

type Manager struct {
	cfg worker.Config // template; Ref and Log are set per connection
	log *slog.Logger

	mu      sync.Mutex
	workers map[string]*worker.Worker
}

func NewManager(cfg worker.Config, log *slog.Logger) *Manager {
	return &Manager{cfg: cfg, log: log, workers: map[string]*worker.Worker{}}
}

func (m *Manager) configFor(ref string) worker.Config {
	c := m.cfg
	c.Ref = ref
	logID, err := keys.LogID(m.cfg.StoreKey, ref)
	if err != nil {
		logID = "unknown"
	}
	c.Log = m.log.With(slog.String("conn", logID))
	return c
}

// Boot resumes every connection with a store on disk: a paired one
// reconnects from its session store, an unpaired one only drains its outbox.
// Pairing is never resumed: the owner restarts it from the connection page.
func (m *Manager) Boot(ctx context.Context) error {
	entries, err := os.ReadDir(m.cfg.DataDir)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, e := range entries {
		ref := e.Name()
		if !e.IsDir() || !ids.ValidConnectionRef(ref) || !worker.Exists(m.cfg.DataDir, ref) {
			continue
		}
		cfg := m.configFor(ref)
		w, err := worker.Open(ctx, cfg)
		if err != nil {
			cfg.Log.Error("boot", slog.String("reason", "open_failed"))
			continue
		}
		if !w.HasSecret() {
			w.Close()
			continue
		}
		if err := w.Start(false); err != nil {
			cfg.Log.Error("boot", slog.String("reason", "start_failed"))
			w.Close()
			continue
		}
		m.workers[ref] = w
		cfg.Log.Info("boot", slog.String("state", "resumed"))
	}
	return nil
}

// StartPairing begins pairing afresh: any device, store and queued events
// the connection had are logged out and deleted first, then a new store
// holds the handed-over callback secret and the session pushes QR codes.
func (m *Manager) StartPairing(ctx context.Context, ref, secret string, version int64) error {
	if secret == "" {
		return worker.ErrNoSecret
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	cfg := m.configFor(ref)

	w := m.workers[ref]
	if w == nil && worker.Exists(m.cfg.DataDir, ref) {
		var err error
		if w, err = worker.Open(ctx, cfg); err != nil {
			return err
		}
	}
	if w != nil {
		if version < w.SecretVersion(ctx) {
			if m.workers[ref] == nil {
				w.Close()
			}
			return worker.ErrStaleSecret
		}
		delete(m.workers, ref)
		if err := w.Unpair(ctx); err != nil {
			return err
		}
	}

	w, err := worker.Open(ctx, cfg)
	if err != nil {
		return err
	}
	if err := w.SetSecret(ctx, secret, version); err != nil {
		w.Close()
		return err
	}
	if err := w.Start(true); err != nil {
		w.Close()
		return err
	}
	m.workers[ref] = w
	cfg.Log.Info("command", slog.String("op", "start_pairing"))
	return nil
}

// Unpair logs the device out and deletes everything the connector holds for
// ref. Unpairing an unknown connection succeeds: there is nothing to delete.
func (m *Manager) Unpair(ctx context.Context, ref string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cfg := m.configFor(ref)
	w := m.workers[ref]
	delete(m.workers, ref)
	if w == nil {
		if !worker.Exists(m.cfg.DataDir, ref) {
			if dir, err := keys.ConnDir(m.cfg.DataDir, ref); err == nil {
				os.RemoveAll(dir)
			}
			return nil
		}
		var err error
		if w, err = worker.Open(ctx, cfg); err != nil {
			return err
		}
	}
	cfg.Log.Info("command", slog.String("op", "unpair"))
	return w.Unpair(ctx)
}

// State reports a worker's state word, or "" when there is none.
func (m *Manager) State(ref string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if w := m.workers[ref]; w != nil {
		return w.State()
	}
	return ""
}

// Close stops every worker and releases its lease.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for ref, w := range m.workers {
		w.Close()
		delete(m.workers, ref)
	}
}
