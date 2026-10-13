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
)

// stubRails sequences like CommsEvents and refuses any event containing
// "POISON" as invalid.
type stubRails struct {
	mu        sync.Mutex
	committed int64
	applied   []string
}

func (s *stubRails) Post(_ context.Context, _ string, _ []byte, body []byte) (rails.Reply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ev struct {
		Seq  int64  `json:"seq"`
		Type string `json:"type"`
	}
	json.Unmarshal(body, &ev)
	c := s.committed
	switch {
	case ev.Seq <= c:
		return rails.Reply{Status: 200, CommittedSeq: &c}, nil
	case ev.Seq > c+1:
		return rails.Reply{Status: 409, Error: "sequence_gap", CommittedSeq: &c}, nil
	case strings.Contains(string(body), "POISON"):
		return rails.Reply{Status: 422, Error: "invalid_record"}, nil
	}
	s.committed = ev.Seq
	s.applied = append(s.applied, string(body))
	n := s.committed
	return rails.Reply{Status: 200, CommittedSeq: &n}, nil
}

func TestPoisonEventIsDroppedAndDeliveryContinues(t *testing.T) {
	r := &stubRails{}
	w, err := Open(context.Background(), Config{
		DataDir: t.TempDir(), Ref: "svc_5", StoreKey: bytes.Repeat([]byte{5}, 32), Rails: r,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.SetSecret(context.Background(), "s", 1)
	ctx := context.Background()
	s := (*sink)(w)
	body := func(text string) *string { return &text }
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "a", Chat: "c", SentAt: time.Now(), Body: body("first")}})
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "b", Chat: "c", SentAt: time.Now(), Body: body("POISON")}})
	s.Messages(ctx, []provider.Message{{ProviderMessageID: "c", Chat: "c", SentAt: time.Now(), Body: body("after")}})

	sctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { w.send(sctx); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		n := len(r.applied)
		r.mu.Unlock()
		if n == 2 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if len(r.applied) != 2 || !strings.Contains(r.applied[0], "first") || !strings.Contains(r.applied[1], "after") {
		t.Fatalf("applied %v", r.applied)
	}
	if depth, _ := w.st.OutboxDepth(ctx); depth != 0 {
		t.Fatalf("outbox depth %d", depth)
	}
}

func TestBatchesStayInsideRailsLimits(t *testing.T) {
	big := strings.Repeat("é", 40<<10) // 80 KiB of UTF-8, past maxText
	var msgs []provider.Message
	for i := 0; i < 450; i++ {
		b := big
		msgs = append(msgs, provider.Message{ProviderMessageID: "m", Chat: "c", Body: &b})
	}
	bodies, err := encodeMessages(msgs)
	if err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, b := range bodies {
		var ev messageEvent
		if err := json.Unmarshal(b, &ev); err != nil {
			t.Fatal(err)
		}
		if len(ev.Messages) > maxBatch || len(b) > 1<<20 {
			t.Fatalf("event of %d messages, %d bytes", len(ev.Messages), len(b))
		}
		for _, m := range ev.Messages {
			if len(*m.Body) > maxText || !strings.HasPrefix(big, *m.Body) {
				t.Fatal("body not clamped at a rune boundary")
			}
		}
		total += len(ev.Messages)
	}
	if total != 450 {
		t.Fatalf("lost messages: %d", total)
	}
}

func TestWithSeq(t *testing.T) {
	if got := string(withSeq([]byte(`{"type":"x"}`), 7)); got != `{"seq":7,"type":"x"}` {
		t.Fatal(got)
	}
}
