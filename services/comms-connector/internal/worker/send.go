package worker

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"log/slog"
	"time"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
)

var (
	// ErrNotConnected: no live paired session to send through. Nothing
	// was recorded or sent.
	ErrNotConnected = errors.New("connection has no live session")
	// ErrSendMismatch: the send_id was seen before with another message
	// id, chat or text (or the message id with another send_id).
	ErrSendMismatch = errors.New("send_id seen before with different content")
	// ErrOutcomeUnknown: the send_id was attempted before and its outcome
	// was never recorded. It is never sent again.
	ErrOutcomeUnknown = errors.New("send was attempted and its outcome is unknown")
	// ErrSendUnknown: this attempt's outcome is unknown (timeout, lost
	// connection, …). Recorded as attempted, so it is never sent again.
	ErrSendUnknown = errors.New("send outcome unknown")
)

// SendRefused: WhatsApp refused the send before accepting it, or it was
// stopped before anything went out. Reason is a fixed word.
type SendRefused struct{ Reason string }

func (e *SendRefused) Error() string { return "send refused: " + e.Reason }

// SendRequest is one send_text command.
type SendRequest struct {
	Attempt   int64
	SendID    string
	MessageID string
	Chat      string
	Text      string
}

// SendResult is a send WhatsApp accepted: its message id and WhatsApp's
// server timestamp (RFC 3339, UTC), byte for byte the same on a replay.
type SendResult struct {
	MessageID string
	SentAt    string
}

// testHookAfterClaim runs after the attempted record is committed and
// before the provider is called (tests only).
var testHookAfterClaim func()

func digest(s string) []byte { d := sha256.Sum256([]byte(s)); return d[:] }

// SendText runs one send_text, at most once per send_id for the life of
// the store:
//
//  1. the attempt must be this worker's pairing attempt (ErrStaleAttempt)
//     and its session live (ErrNotConnected); otherwise nothing is
//     recorded or sent;
//  2. the send is recorded as attempted (send_id, message id, SHA-256 of
//     the chat and of the text, never the text) and committed. If the
//     send_id is already recorded, the provider is not called: a sent
//     one answers its first result again, a refused one its refusal, an
//     attempted one ErrOutcomeUnknown, and one with another message id,
//     chat or text ErrSendMismatch;
//  3. only then is the provider called, and the record moved to sent or
//     refused. An unknown outcome leaves it attempted for ever.
//
// Nothing here logs the chat, the text, the message id or the send id.
func (w *Worker) SendText(ctx context.Context, req SendRequest) (SendResult, error) {
	w.mu.Lock()
	if req.Attempt != w.attempt {
		w.mu.Unlock()
		return SendResult{}, ErrStaleAttempt
	}
	if w.cancel == nil || w.state != "connected" || w.session == nil || !w.session.Online() {
		w.mu.Unlock()
		return SendResult{}, ErrNotConnected
	}
	session, running := w.session, w.ctx
	// Added under w.mu while running, so Stop waits for this send before
	// the store can be closed or reset under it.
	w.bg.Add(1)
	w.mu.Unlock()
	defer w.bg.Done()

	rec := store.Send{SendID: req.SendID, MessageID: req.MessageID,
		ChatDigest: digest(req.Chat), TextDigest: digest(req.Text), State: store.SendAttempted}
	existing, claimed, err := w.st.ClaimSend(ctx, rec)
	if errors.Is(err, store.ErrMessageIDTaken) {
		w.cfg.Log.Info("send", slog.String("refused", "send_mismatch"))
		return SendResult{}, ErrSendMismatch
	}
	if err != nil {
		w.cfg.Log.Error("send", slog.String("reason", "record_failed"))
		return SendResult{}, err
	}
	if !claimed {
		return w.replay(existing, rec)
	}
	if testHookAfterClaim != nil {
		testHookAfterClaim()
	}

	// The send ends with the request or with the session, whichever is
	// first.
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(running, cancel)
	defer stop()
	at, err := session.SendText(sctx, req.Chat, req.MessageID, req.Text)
	// The outcome is recorded even if the request has gone.
	rctx := context.WithoutCancel(ctx)
	var refused *provider.RefusedError
	switch {
	case err == nil:
		if at.IsZero() {
			// The server's ack carried no timestamp; the send succeeded.
			at = time.Now()
		}
		sentAt := at.UTC().Format(time.RFC3339)
		if err := w.st.FinishSend(rctx, req.SendID, store.SendSent, sentAt, ""); err != nil {
			// It was sent; only the record is missing, so a replay will
			// answer outcome_unknown, never send again.
			w.cfg.Log.Error("send", slog.String("reason", "record_failed"))
		}
		w.cfg.Log.Info("send", slog.String("state", "sent"))
		return SendResult{MessageID: req.MessageID, SentAt: sentAt}, nil
	case errors.As(err, &refused):
		if err := w.st.FinishSend(rctx, req.SendID, store.SendRefused, "", refused.Reason); err != nil {
			w.cfg.Log.Error("send", slog.String("reason", "record_failed"))
		}
		w.cfg.Log.Info("send", slog.String("refused", refused.Reason))
		return SendResult{}, &SendRefused{Reason: refused.Reason}
	default:
		w.cfg.Log.Warn("send", slog.String("reason", "outcome_unknown"))
		return SendResult{}, ErrSendUnknown
	}
}

// replay answers a send_id already recorded, without calling the provider.
func (w *Worker) replay(existing, rec store.Send) (SendResult, error) {
	if existing.MessageID != rec.MessageID || !bytes.Equal(existing.ChatDigest, rec.ChatDigest) ||
		!bytes.Equal(existing.TextDigest, rec.TextDigest) {
		w.cfg.Log.Info("send", slog.String("refused", "send_mismatch"))
		return SendResult{}, ErrSendMismatch
	}
	switch existing.State {
	case store.SendSent:
		w.cfg.Log.Info("send", slog.String("replayed", "sent"))
		return SendResult{MessageID: existing.MessageID, SentAt: existing.SentAt}, nil
	case store.SendRefused:
		w.cfg.Log.Info("send", slog.String("replayed", "refused"))
		return SendResult{}, &SendRefused{Reason: existing.Reason}
	default:
		w.cfg.Log.Info("send", slog.String("replayed", "outcome_unknown"))
		return SendResult{}, ErrOutcomeUnknown
	}
}
