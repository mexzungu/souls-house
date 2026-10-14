package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/rails"
	"services/comms-connector/internal/store"
)

// Mira's review of #357: within one attempt the owner can ask for a phone
// code more than once (a replacement number, a retry, another tab). Each
// pair_phone names its request; every result reaching Rails names the
// request it answers, and a result for a request that has since been
// superseded is not posted at all, in whichever order the provider ran them.

const (
	requestA = "aaaaaaaaaaaaaaaa"
	requestB = "bbbbbbbbbbbbbbbb"
)

// gatedSession pairs forever; each phone request blocks until the test
// releases it (keyed by number), then reports what it was given. It ignores
// cancellation on purpose: a provider may still answer a request after it
// was superseded, and the worker must not pass that answer on.
type gatedSession struct {
	mu    sync.Mutex
	gates map[string]chan gatedResult
	done  sync.WaitGroup
}

type gatedResult struct{ code, failure string }

func (g *gatedSession) gate(phone string) chan gatedResult {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.gates[phone] == nil {
		g.gates[phone] = make(chan gatedResult, 1)
	}
	return g.gates[phone]
}

func (g *gatedSession) Run(ctx context.Context, _ provider.Sink, _ bool) error {
	<-ctx.Done()
	return ctx.Err()
}

func (g *gatedSession) Logout(context.Context) error { return nil }

func (g *gatedSession) RequestPhoneCode(_ context.Context, sink provider.Sink, phone string) error {
	g.done.Add(1)
	defer g.done.Done()
	res := <-g.gate(phone)
	if res.failure != "" {
		return sink.PhoneCodeFailed(context.Background(), res.failure)
	}
	now := time.Now()
	return sink.PhoneCode(context.Background(), res.code, now, now.Add(time.Minute))
}

// phoneRails records every phone event it is sent and accepts it.
type phoneRails struct {
	mu     sync.Mutex
	events []map[string]any
}

func (p *phoneRails) Post(_ context.Context, _ string, _ []byte, body []byte) (rails.Reply, error) {
	var ev map[string]any
	json.Unmarshal(body, &ev)
	if t, _ := ev["type"].(string); strings.HasPrefix(t, "pairing.phone_code") {
		p.mu.Lock()
		p.events = append(p.events, ev)
		p.mu.Unlock()
	}
	return rails.Reply{Status: 200}, nil
}

func (p *phoneRails) snapshot() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.events...)
}

func startGated(t *testing.T) (*Worker, *gatedSession, *phoneRails) {
	t.Helper()
	g := &gatedSession{gates: map[string]chan gatedResult{}}
	r := &phoneRails{}
	w, err := Open(context.Background(), Config{
		DataDir: t.TempDir(), Ref: "svc_7", StoreKey: bytes.Repeat([]byte{7}, 32), Rails: r,
		Factory: func(*store.Store) (provider.Session, error) { return g, nil },
		Log:     slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := w.SetSecret(context.Background(), "s3cret", 1); err != nil {
		t.Fatal(err)
	}
	if err := w.Start(true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(w.Close)
	return w, g, r
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// settle lets every released request finish posting (or not) before the
// test reads what Rails got.
func settle(w *Worker, g *gatedSession) {
	g.done.Wait()
	w.bg.Wait()
}

func TestPhoneResultNamesItsRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	waitFor(t, "the code at Rails", func() bool { return len(r.snapshot()) == 1 })
	ev := r.snapshot()[0]
	if ev["type"] != "pairing.phone_code" || ev["code"] != "AAAA-AAAA" || ev["request_id"] != requestA {
		t.Fatalf("event %v", ev)
	}
	g.gate("447700900002") // unused
	if err := w.PairPhone("447700900002", 1, requestB); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{failure: provider.PhoneCodeRateLimited}
	waitFor(t, "the failure at Rails", func() bool { return len(r.snapshot()) == 2 })
	if ev := r.snapshot()[1]; ev["type"] != "pairing.phone_code_failed" || ev["request_id"] != requestB {
		t.Fatalf("event %v", ev)
	}
}

// Delayed success: A's code comes back after B was accepted (and before
// B's): it is not posted; B's is, naming B.
func TestDelayedCodeOfASupersededRequestIsNotPosted(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// Delayed failure: A fails after B got its code; nothing about A is posted,
// so B's code stands.
func TestDelayedFailureOfASupersededRequestIsNotPosted(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	waitFor(t, "B's code at Rails", func() bool { return len(r.snapshot()) == 1 })
	g.gate("447700900001") <- gatedResult{failure: provider.PhoneCodeFailed}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// Reversed execution: B (accepted second) finishes first, then A, whose
// code is the newer one by issue time. Still only B's reaches Rails.
func TestReversedExecutionStillPostsOnlyTheLatestRequest(t *testing.T) {
	w, g, r := startGated(t)
	if err := w.PairPhone("447700900001", 1, requestA); err != nil {
		t.Fatal(err)
	}
	if err := w.PairPhone("447700900002", 1, requestB); err != nil {
		t.Fatal(err)
	}
	g.gate("447700900002") <- gatedResult{code: "BBBB-BBBB"}
	waitFor(t, "B's code at Rails", func() bool { return len(r.snapshot()) == 1 })
	time.Sleep(2 * time.Millisecond) // A's issued_at is strictly later
	g.gate("447700900001") <- gatedResult{code: "AAAA-AAAA"}
	settle(w, g)
	got := r.snapshot()
	if len(got) != 1 || got[0]["code"] != "BBBB-BBBB" || got[0]["request_id"] != requestB {
		t.Fatalf("Rails got %v, want only B's code", got)
	}
}

// A request id must be given: Rails refuses results that name none.
func TestPairPhoneNeedsARequest(t *testing.T) {
	w, _, _ := startGated(t)
	if err := w.PairPhone("447700900001", 1, ""); err == nil {
		t.Fatal("a pair_phone without a request id was accepted")
	}
}
