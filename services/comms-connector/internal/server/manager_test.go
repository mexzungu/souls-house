package server

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/lease"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/worker"
)

const (
	canary = "CANARY-COMMS-mgr-91c2"
	ref    = "svc_7"
	secret = "5ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e75ec2e7abcd"
)

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type rig struct {
	t     *testing.T
	data  string
	key   []byte
	rails *fakeRails
	syn   *provider.Synthetic
	logs  *syncBuf
}

func newRig(t *testing.T) *rig {
	syn := provider.DefaultSynthetic()
	syn.Marker = canary
	syn.QRInterval = 10 * time.Millisecond
	return &rig{t: t, data: t.TempDir(), key: bytes.Repeat([]byte{9}, 32), rails: newFakeRails(t), syn: syn, logs: &syncBuf{}}
}

func (r *rig) manager() *Manager {
	log := slog.New(slog.NewJSONHandler(r.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	m := NewManager(worker.Config{
		DataDir: r.data, StoreKey: r.key, Rails: r.rails.client(r.t), Factory: r.syn.Factory(),
		MinBackoff: 10 * time.Millisecond, MaxBackoff: 50 * time.Millisecond,
	}, log)
	r.t.Cleanup(m.Close)
	return m
}

func (r *rig) wantAllDelivered(want int) {
	r.t.Helper()
	eventually(r.t, "every synthetic message delivered", func() bool { return len(r.rails.messages(ref)) == want })
}

// The synthetic pairing, end to end against a Rails that verifies like the
// real one: QR codes reach Rails while pairing, then connected, then chats
// and messages, all in order with sequence numbers Rails accepts.
func TestPairingDeliversEverythingInOrder(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	if err := m.StartPairing(context.Background(), ref, secret, 1); err != nil {
		t.Fatal(err)
	}
	r.wantAllDelivered(15)
	status, qrs, events, committed := r.rails.snapshot(ref)
	if status != "connected" || len(qrs) != 2 || !strings.HasPrefix(qrs[0], "2@synthetic-0-") {
		t.Fatalf("status %s, qrs %v", status, qrs)
	}
	// QR events are not sequenced; everything else is, from 1 upwards.
	var seqs []string
	for _, ev := range events {
		if ev["type"] != "pairing.qr" {
			seqs = append(seqs, ev["seq"].(interface{ String() string }).String())
		}
	}
	if strings.Join(seqs, ",") != "1,2,3" || committed != 3 {
		t.Fatalf("sequences %v, committed %d", seqs, committed)
	}
	if events[2]["type"] != "status.changed" || events[3]["type"] != "chat.upsert" || events[4]["type"] != "message.upsert" {
		t.Fatalf("order: %v %v %v", events[2]["type"], events[3]["type"], events[4]["type"])
	}
	eventually(t, "outbox drained", func() bool { return m.State(ref) == "connected" })
}

// A restart reconnects from the session store: no new QR, no re-pairing,
// and Rails' committed sequence carries on.
func TestRestartResumesWithoutRepairing(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	r.wantAllDelivered(15)
	m.Close()

	m2 := r.manager()
	if err := m2.Boot(context.Background()); err != nil {
		t.Fatal(err)
	}
	eventually(t, "resumed session re-delivered", func() bool { _, _, _, c := r.rails.snapshot(ref); return c == 6 })
	_, qrs, _, _ := r.rails.snapshot(ref)
	if len(qrs) != 2 {
		t.Fatalf("restart asked for pairing again: %d codes", len(qrs))
	}
}

// Rails being down loses nothing: events wait in the encrypted outbox and
// go out, in order, once it answers again.
func TestRailsOutageLosesNothing(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	r.syn.QRCodes = 0 // pair at once
	r.rails.setDown(true)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	time.Sleep(300 * time.Millisecond)
	if n := len(r.rails.messages(ref)); n != 0 {
		t.Fatalf("delivered while down: %d", n)
	}
	r.rails.setDown(false)
	r.wantAllDelivered(15)
	if status, _, _, _ := r.rails.snapshot(ref); status != "connected" {
		t.Fatal("status lost during outage")
	}
}

// A phone-side logout reaches Rails as logged_out, after everything before it.
func TestPhoneLogoutIsReported(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	signal := make(chan struct{})
	r.syn.LogoutSignal = signal
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	r.wantAllDelivered(15)
	close(signal)
	eventually(t, "logout reported", func() bool { s, _, _, _ := r.rails.snapshot(ref); return s == "reauthorizing" })
}

// Unpair logs the device out and deletes the store and its directory.
func TestUnpairLogsOutAndDeletes(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	r.wantAllDelivered(15)
	if err := m.Unpair(context.Background(), ref); err != nil {
		t.Fatal(err)
	}
	if r.syn.Logouts() != 1 {
		t.Fatalf("logout calls %d", r.syn.Logouts())
	}
	if _, err := os.Stat(filepath.Join(r.data, ref)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("connection directory survived unpair")
	}
	// Unpairing again, or an unknown connection, is fine.
	if err := m.Unpair(context.Background(), ref); err != nil {
		t.Fatal(err)
	}
	if err := m.Unpair(context.Background(), "svc_999"); err != nil {
		t.Fatal(err)
	}
}

// Starting pairing again starts over: the old device is logged out and
// a new store begins, and an older secret version is refused.
func TestStartPairingAgainStartsOverAndRefusesOlderSecret(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 2)
	r.wantAllDelivered(15)
	if err := m.StartPairing(context.Background(), ref, secret, 1); !errors.Is(err, worker.ErrStaleSecret) {
		t.Fatalf("older secret version: %v", err)
	}
	r.rails.expect(ref, secret) // the owner restarted pairing: Rails is pairing again
	if err := m.StartPairing(context.Background(), ref, secret, 2); err != nil {
		t.Fatal(err)
	}
	if r.syn.Logouts() != 1 {
		t.Fatalf("old device not logged out: %d", r.syn.Logouts())
	}
	eventually(t, "re-paired", func() bool { _, qrs, _, c := r.rails.snapshot(ref); return len(qrs) == 4 && c == 6 })
}

// The lease holds across processes' worth of managers on one volume: a
// second manager cannot open a connection the first is running.
func TestSecondManagerCannotTakeALiveConnection(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	r.wantAllDelivered(15)

	dir, _ := keys.ConnDir(r.data, ref)
	if _, err := lease.Acquire(dir); !errors.Is(err, lease.ErrHeld) {
		t.Fatalf("lease not held: %v", err)
	}
	m2 := r.manager()
	m2.Boot(context.Background())
	if m2.State(ref) != "" {
		t.Fatal("second manager runs the same connection")
	}
	if err := m2.StartPairing(context.Background(), ref, secret, 1); err == nil {
		t.Fatal("second manager re-paired a live connection")
	}
}

// §3: the connector logs no bodies, names, JIDs, QR codes or keys. Run the
// whole lifecycle and grep the logs for the canary, the secret and the ref.
func TestLogsCarryNoContent(t *testing.T) {
	r := newRig(t)
	r.rails.expect(ref, secret)
	signal := make(chan struct{})
	r.syn.LogoutSignal = signal
	r.rails.setDown(true)
	m := r.manager()
	m.StartPairing(context.Background(), ref, secret, 1)
	time.Sleep(200 * time.Millisecond)
	r.rails.setDown(false)
	r.wantAllDelivered(15)
	close(signal)
	eventually(t, "logout", func() bool { s, _, _, _ := r.rails.snapshot(ref); return s == "reauthorizing" })
	m.Unpair(context.Background(), ref)

	logs := r.logs.String()
	if logs == "" {
		t.Fatal("no logs captured; the check would prove nothing")
	}
	for _, needle := range []string{canary, secret, ref, "4477009", "synthetic-0", "Synthetic"} {
		if strings.Contains(logs, needle) {
			t.Errorf("logs contain %q", needle)
		}
	}
	// And the canary really went through (so its absence above means something).
	if !strings.Contains(strings.Join(r.rails.raw, ""), canary) {
		t.Fatal("canary never reached Rails")
	}
}
