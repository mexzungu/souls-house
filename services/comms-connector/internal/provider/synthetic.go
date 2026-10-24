package provider

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"services/comms-connector/internal/store"
)

// Synthetic is a deterministic stand-in for WhatsApp. Pairing pushes
// QRCodes codes QRInterval apart and then succeeds; once paired (recorded in
// the store, so it survives a restart) every Run reports Connected and the
// same chats and messages. The same configuration always produces the same
// ids and content, so a replay is a no-op in Rails.
type Synthetic struct {
	QRCodes         int
	QRInterval      time.Duration
	QRLifetime      time.Duration
	Chats           int
	MessagesPerChat int
	// Marker is embedded in every name and body. Tests set a canary.
	Marker string
	Base   time.Time
	// LogoutSignal, when closed, makes a running session behave as if the
	// phone removed the device.
	LogoutSignal <-chan struct{}
	// PhoneCode is the code RequestPhoneCode reports (default SYNT-HABC);
	// PhoneFailure, when set, is reported instead.
	PhoneCode    string
	PhoneFailure string
	// PhoneCodeLifetime is how long a phone code is reported to last
	// (default QRLifetime).
	PhoneCodeLifetime time.Duration
	// SendHook, when set, decides what SendText does (tests: success,
	// refusal, an ambiguous error, a hang until ctx ends, a crash). Unset,
	// a send succeeds at the current second. See SendRefusing,
	// SendAmbiguous and SendHanging.
	SendHook func(ctx context.Context, chat, messageID, text string) (time.Time, error)
	// EchoSends: after a successful send, the session reports the message
	// back as received, from the paired account, with the same message id,
	// as WhatsApp does on the account's other devices.
	EchoSends bool

	logouts     atomic.Int32
	phoneCodes  atomic.Int32
	sends       atomic.Int32
	lastPhoneMu sync.Mutex
	lastPhone   string
	eventsMu    sync.Mutex // Chats and MessagesPerChat, once sessions run
}

func DefaultSynthetic() *Synthetic {
	return &Synthetic{
		QRCodes: 2, QRInterval: 200 * time.Millisecond, QRLifetime: 20 * time.Second,
		Chats: 3, MessagesPerChat: 5,
		Base:      time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC),
		EchoSends: true,
	}
}

// SyntheticOwnID is the synthetic paired account's user id.
const SyntheticOwnID = "447700900000"

// SendRefusing is a SendHook that refuses every send with reason.
func SendRefusing(reason string) func(context.Context, string, string, string) (time.Time, error) {
	return func(context.Context, string, string, string) (time.Time, error) {
		return time.Time{}, &RefusedError{Reason: reason}
	}
}

// SendAmbiguous is a SendHook whose every send has an unknown outcome.
func SendAmbiguous(context.Context, string, string, string) (time.Time, error) {
	return time.Time{}, ErrSendUnknown
}

// SendHanging is a SendHook that never answers: it returns ctx's error
// once ctx ends, as whatsmeow does while waiting for the server's ack.
func SendHanging(ctx context.Context, _, _, _ string) (time.Time, error) {
	<-ctx.Done()
	return time.Time{}, ctx.Err()
}

// Sends counts SendText calls that reached the provider (tests).
func (s *Synthetic) Sends() int { return int(s.sends.Load()) }

// Factory returns a provider.Factory sharing this configuration.
func (s *Synthetic) Factory() Factory {
	return func(st *store.Store) (Session, error) {
		return &syntheticSession{cfg: s, st: st, ready: make(chan struct{}), ended: make(chan struct{})}, nil
	}
}

// Logouts counts Logout calls on paired sessions (for tests).
func (s *Synthetic) Logouts() int { return int(s.logouts.Load()) }

// SetEvents changes how many chats and messages a paired session reports,
// safely while sessions are running.
func (s *Synthetic) SetEvents(chats, messagesPerChat int) {
	s.eventsMu.Lock()
	defer s.eventsMu.Unlock()
	s.Chats, s.MessagesPerChat = chats, messagesPerChat
}

// PhoneCodes counts phone codes reported; LastPhone is the number the last
// request named (tests only: the real provider keeps neither).
func (s *Synthetic) PhoneCodes() int { return int(s.phoneCodes.Load()) }

func (s *Synthetic) LastPhone() string {
	s.lastPhoneMu.Lock()
	defer s.lastPhoneMu.Unlock()
	return s.lastPhone
}

// Events returns the chats and messages a paired session reports.
func (s *Synthetic) Events() ([]Chat, []Message) {
	s.eventsMu.Lock()
	nChats, perChat := s.Chats, s.MessagesPerChat
	s.eventsMu.Unlock()
	var chats []Chat
	var msgs []Message
	for c := 0; c < nChats; c++ {
		chatID := fmt.Sprintf("4477009%05d@s.whatsapp.net", c)
		var last time.Time
		for m := 0; m < perChat; m++ {
			at := s.Base.Add(time.Duration(c)*time.Hour + time.Duration(m)*time.Minute).UTC()
			last = at
			body := fmt.Sprintf("Synthetic message %d in chat %d %s", m, c, s.Marker)
			msg := Message{
				ProviderMessageID: fmt.Sprintf("SYN%02d%05d", c, m),
				Chat:              chatID,
				SenderID:          chatID,
				SenderName:        fmt.Sprintf("Synthetic sender %d %s", c, s.Marker),
				SentAt:            at,
				Body:              &body,
			}
			if m == 1 { // one media message per chat: kind and caption, no body
				kind, caption := "image", fmt.Sprintf("Synthetic caption %s", s.Marker)
				msg.Body, msg.MediaKind, msg.Caption = nil, &kind, &caption
			}
			msgs = append(msgs, msg)
		}
		lastCopy := last
		chats = append(chats, Chat{ProviderChatID: chatID, Name: fmt.Sprintf("Synthetic chat %d %s", c, s.Marker), Kind: "direct", LastActivityAt: &lastCopy})
	}
	return chats, msgs
}

type syntheticSession struct {
	cfg *Synthetic
	st  *store.Store

	ready     chan struct{} // closed with the first QR
	ended     chan struct{} // closed when pairing ends, either way
	readyOnce sync.Once
	endOnce   sync.Once

	mu     sync.Mutex
	online bool
	sink   Sink // Run's, while online
}

const syntheticPaired = "synthetic_paired"

func (s *syntheticSession) paired(ctx context.Context) (bool, error) {
	v, ok, err := s.st.Meta(ctx, syntheticPaired)
	return ok && v == "1", err
}

func (s *syntheticSession) Run(ctx context.Context, sink Sink, pair bool) error {
	defer s.endOnce.Do(func() { close(s.ended) })
	paired, err := s.paired(ctx)
	if err != nil {
		return err
	}
	if !paired {
		if !pair {
			return ErrNotPaired
		}
		for i := 0; i < s.cfg.QRCodes; i++ {
			now := time.Now().UTC()
			// Rails orders codes by issued_at at second precision.
			if err := sink.QR(ctx, fmt.Sprintf("2@synthetic-%d-%s", i, s.cfg.Marker), now, now.Add(s.cfg.QRLifetime)); err != nil {
				return err
			}
			s.readyOnce.Do(func() { close(s.ready) })
			if err := sleep(ctx, s.cfg.QRInterval); err != nil {
				return err
			}
		}
		if err := s.st.SetMeta(ctx, map[string]string{syntheticPaired: "1"}); err != nil {
			return err
		}
	}
	s.endOnce.Do(func() { close(s.ended) })
	if err := sink.Connected(ctx, Identity{UserID: SyntheticOwnID, DisplayName: "Synthetic " + s.cfg.Marker}); err != nil {
		return err
	}
	s.mu.Lock()
	s.online, s.sink = true, sink
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.online, s.sink = false, nil
		s.mu.Unlock()
	}()
	chats, msgs := s.cfg.Events()
	if err := sink.Chats(ctx, chats); err != nil {
		return err
	}
	if err := sink.Messages(ctx, msgs); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.cfg.LogoutSignal:
		if err := s.st.SetMeta(context.WithoutCancel(ctx), map[string]string{syntheticPaired: "0"}); err != nil {
			return err
		}
		if err := sink.LoggedOut(ctx); err != nil {
			return err
		}
		return ErrLoggedOut
	}
}

func (s *syntheticSession) Online() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.online
}

// SendText checks the chat as the whatsmeow session does, counts the call,
// then does what SendHook says (or succeeds), and echoes a success back
// as a received message when EchoSends is set. The text is kept nowhere.
func (s *syntheticSession) SendText(ctx context.Context, chat, messageID, text string) (time.Time, error) {
	if _, err := ParseChat(chat); err != nil {
		return time.Time{}, &RefusedError{Reason: RefusedBadChat}
	}
	s.mu.Lock()
	online, sink := s.online, s.sink
	s.mu.Unlock()
	if !online {
		return time.Time{}, &RefusedError{Reason: RefusedNotConnected}
	}
	s.cfg.sends.Add(1)
	at := time.Now().UTC().Truncate(time.Second)
	if s.cfg.SendHook != nil {
		var err error
		if at, err = s.cfg.SendHook(ctx, chat, messageID, text); err != nil {
			return time.Time{}, err
		}
	}
	if s.cfg.EchoSends {
		own := SyntheticOwnID + "@s.whatsapp.net"
		body := text
		echo := Message{ProviderMessageID: messageID, Chat: chat, SenderID: own,
			SenderName: "Synthetic " + s.cfg.Marker, SentAt: at, Body: &body}
		// Best effort, like WhatsApp's own echo: the send has succeeded
		// whether or not the echo is stored.
		_ = sink.Messages(context.WithoutCancel(ctx), []Message{echo})
	}
	return at, nil
}

// RequestPhoneCode waits for the first QR, as whatsmeow's PairPhone needs,
// then reports the configured code or failure.
func (s *syntheticSession) RequestPhoneCode(ctx context.Context, sink Sink, phone string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.ended:
		return ErrNotPairing
	case <-s.ready:
	}
	select {
	case <-s.ended:
		return ErrNotPairing
	default:
	}
	s.cfg.lastPhoneMu.Lock()
	s.cfg.lastPhone = phone
	s.cfg.lastPhoneMu.Unlock()
	if s.cfg.PhoneFailure != "" {
		return sink.PhoneCodeFailed(ctx, s.cfg.PhoneFailure)
	}
	code := s.cfg.PhoneCode
	if code == "" {
		code = "SYNT-HABC"
	}
	lifetime := s.cfg.PhoneCodeLifetime
	if lifetime == 0 {
		lifetime = s.cfg.QRLifetime
	}
	now := time.Now().UTC()
	s.cfg.phoneCodes.Add(1)
	return sink.PhoneCode(ctx, code, now, now.Add(lifetime))
}

func (s *syntheticSession) Logout(ctx context.Context) error {
	if paired, err := s.paired(ctx); err != nil || !paired {
		return err
	}
	s.cfg.logouts.Add(1)
	return s.st.SetMeta(ctx, map[string]string{syntheticPaired: "0"})
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
