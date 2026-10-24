package worker

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"testing"
	"time"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
)

const (
	sendRef   = "svc_9"
	sendChat  = "447700900002@s.whatsapp.net"
	sendText  = "Hello from the house CANARY-COMMS-send-3c9b"
	sendMsgID = "3EB00123456789ABCDEF"
	sendID    = "snd_42"
)

var sendKey = bytes.Repeat([]byte{4}, 32)

func sendReq() SendRequest {
	return SendRequest{Attempt: 1, SendID: sendID, MessageID: sendMsgID, Chat: sendChat, Text: sendText}
}

// startSending opens a worker on dir with a synthetic provider that pairs
// at once, starts it and waits until it is connected.
func startSending(t *testing.T, dir string, syn *provider.Synthetic) *Worker {
	t.Helper()
	w, err := Open(context.Background(), Config{
		DataDir: dir, Ref: sendRef, StoreKey: sendKey, Rails: &stubRails{}, Factory: syn.Factory(),
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)), MinBackoff: time.Millisecond, MaxBackoff: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !w.HasSecret() {
		if err := w.SetSecret(context.Background(), "s3cret", 1); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Start(true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "connected", func() bool { return w.State() == "connected" })
	return w
}

func syntheticSender() *provider.Synthetic {
	syn := provider.DefaultSynthetic()
	syn.QRCodes, syn.Chats, syn.EchoSends = 0, 0, false
	return syn
}

func record(t *testing.T, w *Worker) (store.Send, bool) {
	t.Helper()
	rec, ok, err := w.st.GetSend(context.Background(), sendID)
	if err != nil {
		t.Fatal(err)
	}
	return rec, ok
}

// A send WhatsApp accepts: recorded as sent with digests only; the same
// send_id again answers the same result without a second provider call;
// the same send_id with anything else changed is a mismatch.
func TestSendTextSucceedsOnceAndReplays(t *testing.T) {
	syn := syntheticSender()
	at := time.Date(2026, 10, 24, 10, 0, 7, 0, time.UTC)
	syn.SendHook = func(context.Context, string, string, string) (time.Time, error) { return at, nil }
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	ctx := context.Background()

	res, err := w.SendText(ctx, sendReq())
	if err != nil || res.MessageID != sendMsgID || res.SentAt != "2026-10-24T10:00:07Z" {
		t.Fatalf("send: %+v %v", res, err)
	}
	rec, ok := record(t, w)
	chatSum, textSum := sha256.Sum256([]byte(sendChat)), sha256.Sum256([]byte(sendText))
	if !ok || rec.State != store.SendSent || rec.SentAt != res.SentAt || rec.MessageID != sendMsgID ||
		!bytes.Equal(rec.ChatDigest, chatSum[:]) || !bytes.Equal(rec.TextDigest, textSum[:]) {
		t.Fatalf("record %+v", rec)
	}

	again, err := w.SendText(ctx, sendReq())
	if err != nil || again != res {
		t.Fatalf("replay: %+v %v", again, err)
	}
	for name, change := range map[string]func(*SendRequest){
		"text":                             func(r *SendRequest) { r.Text += "!" },
		"chat":                             func(r *SendRequest) { r.Chat = "447700900003@s.whatsapp.net" },
		"message id":                       func(r *SendRequest) { r.MessageID = "3EB0FFFFFFFFFFFFFFFF" },
		"message id under another send id": func(r *SendRequest) { r.SendID = "snd_43" },
	} {
		req := sendReq()
		change(&req)
		if _, err := w.SendText(ctx, req); !errors.Is(err, ErrSendMismatch) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if n := syn.Sends(); n != 1 {
		t.Fatalf("provider called %d times", n)
	}
}

// A definitive refusal is recorded and answered again on replay.
func TestSendTextRefusalIsRecorded(t *testing.T) {
	syn := syntheticSender()
	syn.SendHook = provider.SendRefusing(provider.RefusedNotOnWhatsApp)
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	for i := 0; i < 2; i++ {
		_, err := w.SendText(context.Background(), sendReq())
		var refused *SendRefused
		if !errors.As(err, &refused) || refused.Reason != "not_on_whatsapp" {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	if rec, _ := record(t, w); rec.State != store.SendRefused || rec.Reason != "not_on_whatsapp" {
		t.Fatalf("record %+v", rec)
	}
	if syn.Sends() != 1 {
		t.Fatalf("provider called %d times", syn.Sends())
	}
}

// An unknown outcome (an ambiguous error, or no answer before the request
// ends) stays attempted, and the send_id is never sent again.
func TestSendTextUnknownOutcomeIsNeverResent(t *testing.T) {
	for name, hook := range map[string]func(context.Context, string, string, string) (time.Time, error){
		"ambiguous error": provider.SendAmbiguous,
		"hang":            provider.SendHanging,
	} {
		t.Run(name, func(t *testing.T) {
			syn := syntheticSender()
			syn.SendHook = hook
			w := startSending(t, t.TempDir(), syn)
			defer w.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer cancel()
			if _, err := w.SendText(ctx, sendReq()); !errors.Is(err, ErrSendUnknown) {
				t.Fatalf("first: %v", err)
			}
			if rec, _ := record(t, w); rec.State != store.SendAttempted {
				t.Fatalf("record %+v", rec)
			}
			syn.SendHook = nil // it would succeed now; it must not be tried
			if _, err := w.SendText(context.Background(), sendReq()); !errors.Is(err, ErrOutcomeUnknown) {
				t.Fatalf("replay: %v", err)
			}
			if syn.Sends() != 1 {
				t.Fatalf("provider called %d times", syn.Sends())
			}
		})
	}
}

// stale_attempt and not_connected are answered before anything is
// recorded or sent: the same send_id later still goes out.
func TestStaleAttemptAndNotConnectedRecordNothing(t *testing.T) {
	syn := syntheticSender()
	dir := t.TempDir()
	w := startSending(t, dir, syn)
	stale := sendReq()
	stale.Attempt = 2
	if _, err := w.SendText(context.Background(), stale); !errors.Is(err, ErrStaleAttempt) {
		t.Fatalf("stale attempt: %v", err)
	}
	if _, ok := record(t, w); ok {
		t.Fatal("a stale attempt was recorded")
	}
	w.Stop()
	if _, err := w.SendText(context.Background(), sendReq()); !errors.Is(err, ErrNotConnected) {
		t.Fatalf("stopped worker: %v", err)
	}
	if _, ok := record(t, w); ok {
		t.Fatal("a send without a session was recorded")
	}
	if syn.Sends() != 0 {
		t.Fatalf("provider called %d times", syn.Sends())
	}
	w.Close()

	w = startSending(t, dir, syn)
	defer w.Close()
	if _, err := w.SendText(context.Background(), sendReq()); err != nil {
		t.Fatalf("the same send_id, now current and connected: %v", err)
	}
}

// Duplicate requests for one send_id at once: one provider call. The
// others answer outcome_unknown (still in flight) or the replayed result.
func TestConcurrentDuplicatesCallTheProviderOnce(t *testing.T) {
	syn := syntheticSender()
	syn.SendHook = func(context.Context, string, string, string) (time.Time, error) {
		time.Sleep(100 * time.Millisecond)
		return time.Now(), nil
	}
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	const n = 16
	var wg sync.WaitGroup
	errs := make([]error, n)
	start := make(chan struct{})
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, errs[i] = w.SendText(context.Background(), sendReq())
		}()
	}
	close(start)
	wg.Wait()
	if syn.Sends() != 1 {
		t.Fatalf("provider called %d times", syn.Sends())
	}
	for i, err := range errs {
		if err != nil && !errors.Is(err, ErrOutcomeUnknown) {
			t.Errorf("request %d: %v", i, err)
		}
	}
}

// The record of sends survives a restarted pairing: a send_id already sent
// under the old attempt is answered from the record, not sent again.
func TestSendsSurviveARestartedPairing(t *testing.T) {
	syn := syntheticSender()
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	first, err := w.SendText(context.Background(), sendReq())
	if err != nil {
		t.Fatal(err)
	}
	if err := w.ResetForPairing(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := w.SetSecret(context.Background(), "s3cret", 2); err != nil {
		t.Fatal(err)
	}
	if err := w.Start(true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "connected again", func() bool { return w.State() == "connected" })
	req := sendReq()
	req.Attempt = 2
	if again, err := w.SendText(context.Background(), req); err != nil || again != first {
		t.Fatalf("after re-pairing: %+v %v", again, err)
	}
	if syn.Sends() != 1 {
		t.Fatalf("provider called %d times", syn.Sends())
	}
}

// The process dies between the committed attempted record and the
// provider's answer (os.Exit inside the provider call, so nothing after
// it runs, deferred or not). After a restart (a fresh worker on the same
// store) the send_id answers outcome_unknown and the provider is not
// called.
func TestCrashBetweenAttemptAndResultNeverResends(t *testing.T) {
	if dir := os.Getenv("COMMS_SEND_CRASH_DIR"); dir != "" {
		syn := syntheticSender()
		syn.SendHook = func(context.Context, string, string, string) (time.Time, error) {
			os.Exit(3) // the crash: mid-call, before any answer
			return time.Time{}, nil
		}
		w := startSending(t, dir, syn)
		w.SendText(context.Background(), sendReq())
		os.Exit(4) // not reached when the provider was called
	}
	dir := t.TempDir()
	cmd := exec.Command(os.Args[0], "-test.run=^TestCrashBetweenAttemptAndResultNeverResends$")
	cmd.Env = append(os.Environ(), "COMMS_SEND_CRASH_DIR="+dir)
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 3 {
		t.Fatalf("the child did not die inside the provider call: %v %s", err, out)
	}

	syn := syntheticSender()
	w := startSending(t, dir, syn)
	defer w.Close()
	if rec, ok := record(t, w); !ok || rec.State != store.SendAttempted {
		t.Fatalf("after the crash: %+v %v", rec, ok)
	}
	if _, err := w.SendText(context.Background(), sendReq()); !errors.Is(err, ErrOutcomeUnknown) {
		t.Fatalf("after restart: %v", err)
	}
	if syn.Sends() != 0 {
		t.Fatalf("the provider was called again after the crash: %d", syn.Sends())
	}
}

// A recorded send_id is answered from its record whatever the connection's
// state or attempt: sent → the identical result, refused → the same
// refusal, attempted → outcome_unknown; the provider is not called. Only
// an unrecorded send_id meets stale_attempt / not_connected.
func TestReplayIsAnsweredFromTheRecordWhateverTheConnection(t *testing.T) {
	syn := syntheticSender()
	syn.SendHook = func(_ context.Context, _, messageID, _ string) (time.Time, error) {
		switch messageID {
		case "3EB0000000000000BBBB":
			return time.Time{}, &provider.RefusedError{Reason: provider.RefusedNotOnWhatsApp}
		case "3EB0000000000000CCCC":
			return time.Time{}, provider.ErrSendUnknown
		}
		return time.Date(2026, 10, 24, 10, 0, 7, 0, time.UTC), nil
	}
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	ctx := context.Background()
	sent := sendReq()
	refusedReq := SendRequest{Attempt: 1, SendID: "snd_r", MessageID: "3EB0000000000000BBBB", Chat: sendChat, Text: sendText}
	unsure := SendRequest{Attempt: 1, SendID: "snd_u", MessageID: "3EB0000000000000CCCC", Chat: sendChat, Text: sendText}
	first, err := w.SendText(ctx, sent)
	if err != nil {
		t.Fatal(err)
	}
	w.SendText(ctx, refusedReq)
	w.SendText(ctx, unsure)

	staleReq := func(r SendRequest) SendRequest { r.Attempt = 7; return r }
	check := func(when string) {
		t.Helper()
		for _, r := range []SendRequest{sent, staleReq(sent)} {
			if again, err := w.SendText(ctx, r); err != nil || again != first {
				t.Errorf("%s: sent replay (attempt %d): %+v %v", when, r.Attempt, again, err)
			}
		}
		for _, r := range []SendRequest{refusedReq, staleReq(refusedReq)} {
			var refused *SendRefused
			if _, err := w.SendText(ctx, r); !errors.As(err, &refused) || refused.Reason != "not_on_whatsapp" {
				t.Errorf("%s: refused replay (attempt %d): %v", when, r.Attempt, err)
			}
		}
		for _, r := range []SendRequest{unsure, staleReq(unsure)} {
			if _, err := w.SendText(ctx, r); !errors.Is(err, ErrOutcomeUnknown) {
				t.Errorf("%s: attempted replay (attempt %d): %v", when, r.Attempt, err)
			}
		}
		// A changed text is still a mismatch, connected or not.
		changed := sent
		changed.Text += "!"
		if _, err := w.SendText(ctx, changed); !errors.Is(err, ErrSendMismatch) {
			t.Errorf("%s: mismatch: %v", when, err)
		}
	}
	check("connected")
	w.Stop() // disconnected: no session at all
	check("disconnected")
	if syn.Sends() != 3 {
		t.Fatalf("provider called %d times, want 3", syn.Sends())
	}
	// An unrecorded send_id, disconnected or stale, records nothing.
	fresh := SendRequest{Attempt: 1, SendID: "snd_new", MessageID: "3EB0000000000000DDDD", Chat: sendChat, Text: sendText}
	if _, err := w.SendText(ctx, fresh); !errors.Is(err, ErrNotConnected) {
		t.Fatalf("new send, disconnected: %v", err)
	}
	if _, err := w.SendText(ctx, staleReq(fresh)); !errors.Is(err, ErrStaleAttempt) {
		t.Fatalf("new send, stale: %v", err)
	}
	if _, ok, _ := w.st.GetSend(ctx, "snd_new"); ok {
		t.Fatal("a refused new send was recorded")
	}
	// A closed worker answers not_connected, never a store error.
	w.Close()
	if _, err := w.SendText(ctx, sent); !errors.Is(err, ErrNotConnected) {
		t.Fatalf("closed worker: %v", err)
	}
}

// A store failure is returned only before the provider is called (500
// send_failed at the handler): with the database gone, nothing is sent.
func TestStoreFailureIsBeforeTheProvider(t *testing.T) {
	syn := syntheticSender()
	w := startSending(t, t.TempDir(), syn)
	defer w.Close()
	w.st.Close() // the database fails under a running worker
	_, err := w.SendText(context.Background(), sendReq())
	if !errors.Is(err, store.ErrStore) {
		t.Fatalf("got %v", err)
	}
	if syn.Sends() != 0 {
		t.Fatalf("provider called %d times", syn.Sends())
	}
}
