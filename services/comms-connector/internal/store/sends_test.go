package store

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"path/filepath"
	"testing"
)

func sendRec(id, msgID string) Send {
	c, x := sha256.Sum256([]byte("chat")), sha256.Sum256([]byte("text"))
	return Send{SendID: id, MessageID: msgID, ChatDigest: c[:], TextDigest: x[:]}
}

// A claim is written and committed; a second claim for the send_id
// returns the record without writing; finishing moves attempted on once.
func TestClaimAndFinishSend(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "s.db")
	key := randKey(t)
	s := openT(t, path, key)
	if _, claimed, err := s.ClaimSend(ctx, sendRec("a", "3EB00000000000000001")); err != nil || !claimed {
		t.Fatalf("claim: %v %v", claimed, err)
	}
	s.Close()

	// Committed: another open of the file sees it attempted.
	s = openT(t, path, key)
	defer s.Close()
	got, claimed, err := s.ClaimSend(ctx, sendRec("a", "3EB00000000000000001"))
	if err != nil || claimed || got.State != SendAttempted || got.MessageID != "3EB00000000000000001" {
		t.Fatalf("reclaim: %+v %v %v", got, claimed, err)
	}
	if _, _, err := s.ClaimSend(ctx, sendRec("b", "3EB00000000000000001")); !errors.Is(err, ErrMessageIDTaken) {
		t.Fatalf("message id reused: %v", err)
	}
	if _, _, err := s.ClaimSend(ctx, Send{SendID: "c", MessageID: "x", ChatDigest: []byte("short")}); !errors.Is(err, ErrBadInput) {
		t.Fatalf("bad input: %v", err)
	}
	if err := s.FinishSend(ctx, "a", SendSent, "2026-10-24T10:00:00Z", ""); err != nil {
		t.Fatal(err)
	}
	// A finished send is not finished again.
	if err := s.FinishSend(ctx, "a", SendRefused, "", "late"); err != nil {
		t.Fatal(err)
	}
	got, ok, err := s.GetSend(ctx, "a")
	if err != nil || !ok || got.State != SendSent || got.SentAt != "2026-10-24T10:00:00Z" || got.Reason != "" {
		t.Fatalf("finished: %+v %v %v", got, ok, err)
	}
	if err := s.FinishSend(ctx, "a", SendAttempted, "", ""); !errors.Is(err, ErrBadInput) {
		t.Fatalf("back to attempted: %v", err)
	}
}

// A store created before sends existed gets the table when it is opened.
func TestSendsTableIsAddedToAnOlderStore(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "s.db")
	key := randKey(t)
	s := openT(t, path, key)
	if _, err := s.DB().ExecContext(ctx, `DROP TABLE sends`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s = openT(t, path, key)
	defer s.Close()
	if _, claimed, err := s.ClaimSend(ctx, sendRec("a", "3EB00000000000000001")); err != nil || !claimed {
		t.Fatalf("claim on the migrated store: %v %v", claimed, err)
	}
}

// A restarted pairing keeps the record of sends.
func TestResetSessionKeepsSends(t *testing.T) {
	ctx := context.Background()
	s := openT(t, filepath.Join(t.TempDir(), "s.db"), randKey(t))
	defer s.Close()
	rec := sendRec("a", "3EB00000000000000001")
	s.ClaimSend(ctx, rec)
	if err := s.ResetSession(ctx, func([]byte) bool { return false }); err != nil {
		t.Fatal(err)
	}
	got, ok, err := s.GetSend(ctx, "a")
	if err != nil || !ok || !bytes.Equal(got.TextDigest, rec.TextDigest) {
		t.Fatalf("after reset: %+v %v %v", got, ok, err)
	}
}
